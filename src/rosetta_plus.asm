; Rosetta+ (0.28): MIDI clock sync, LOOPER freeze, LO-FI. Included by rosetta_hi.asm; plus_tick runs from hi_tick
; every main-loop pass (DS = 0), lf_run from lr_fill (rosetta_lrev.asm).
;
; MIDI CLOCK: the OS's MIDI ISR (0FE4:0C66) puts every byte it gets, realtime ones too, into a 256 B ring at 0:0300
; (write pointer [73A0]). We read that ring behind the OS's own parser (no hook, nothing consumed), count F8s and
; time every 96 (a bar) with the OS tick (0.511 ms): one main-loop pass (~5 ms) of jitter over ~2 s, smoothed.
; With CLK on (REV menu page 5, or CC 31 >= 64):
;   - the live reverse's BPM follows (unless it is FREE)
;   - echo types (1-6 static taps, no LFO, first tap >= 100 ms: ECHO, PINGPONG, DUB, LOOPER) get their tap
;     lengths from the beat instead of TIME: the first tap = the note value (1/16 .. 4 bars, by halves / doubles)
;     nearest its designed length, the others in proportion
;   - LFO (REV menu page 5): the FX LFO rates the same way, slot 0 = a note value of the bar near its own rate
; Clock stopped (no F8 for 0.3 s): the last tempo stays. CLK off: the FX page's TIME / RATE are back at once.
;
; LOOPER (FX type): taps at T (TIME 25-200 % = 0.19-1.49 s), FB 0-99 = how much of each pass stays.
; FREEZE = FB at 100, or CC 30 >= 64: the loop's feedback = 1.0, every send into the delay engine cut (voices
; and the live input), so the loop holds what it has; letting go = the sends back (new notes at once).
CK_RING   equ 0x0300
CK_WP     equ 0x73A0
CK_TICK   equ 0x73DA              ; (a byte: ++ every 0.511 ms)
RETF_LO   equ LO_lfo_run - 1      ; the lo `retf` that ends lfo_hook (mkbaby.py checks the byte)

%macro LOCALL 1                   ; near-call a lo (MENU_SEG) routine from here
        push cs
        push %%back
        push RETF_LO
        jmp MENU_SEG:%1
%%back:
%endmacro

plus_tick:
        call ck_scan
        call ck_apply
        jmp fz_run

; ---------------------------------------------------------------------------------------------
ck_scan:
        mov al, [CK_TICK]         ; the OS tick is a byte: our own 16-bit count from it (a pass < 128 ms apart)
        sub al, [cs:ck_lb]
        add [cs:ck_lb], al
        xor ah, ah
        add [cs:ck_now], ax
        mov dx, [cs:ck_now]
        mov bx, [cs:ck_rp]
        or bx, bx
        jnz .l
        mov bx, [CK_WP]           ; first pass: start at the OS's write pointer
.l:     cmp bx, [CK_WP]
        je .d
        mov al, [bx]
        inc bl
        cmp al, 0xF8
        je .clk
        cmp al, 0xFA              ; START / CONTINUE: count afresh
        je .rs
        cmp al, 0xFB
        jne .l
.rs:    mov byte [cs:ck_n], 0
        jmp .l
.clk:   mov ax, dx                ; gap since the last clock > 0.3 s: it had stopped
        sub ax, [cs:ck_lt]
        mov [cs:ck_lt], dx
        cmp ax, 600
        jb .c1
        mov byte [cs:ck_n], 0
.c1:    inc byte [cs:ck_n]
        cmp byte [cs:ck_n], 1
        jne .c2
        mov [cs:ck_t0], dx
        jmp .l
.c2:    cmp byte [cs:ck_n], 97
        jb .l
        mov byte [cs:ck_n], 1
        mov ax, dx
        sub ax, [cs:ck_t0]        ; ticks for a bar (96 clocks)
        mov [cs:ck_t0], dx
        cmp ax, 600               ; > 390 bpm: junk
        jb .l
        push dx
        push bx
        mov cx, [cs:ck_dt]        ; within 2 % of the last bar: smoothed 3:1 (the pass jitter), else taken as is
        mov bx, cx
        shr bx, 6
        mov dx, ax
        sub dx, cx
        jns .a1
        neg dx
.a1:    cmp dx, bx
        ja .a2
        mov dx, cx
        shl cx, 1
        add cx, dx
        add cx, ax
        add cx, 2
        shr cx, 1
        shr cx, 1
        mov ax, cx
.a2:    mov [cs:ck_dt], ax
        mov cx, ax
        shr ax, 1                 ; bpm = 60000 x 4 / (dt x 0.511), rounded
        add ax, 469667 & 0xFFFF
        mov dx, 469667 >> 16
        adc dx, 0
        div cx
        mov [cs:ck_bpm], ax
        mov ax, cx                ; a beat in samples = dt / 4 x 22.535 = dt x 5769 / 1024
        mov bx, 5769
        mul bx
        cmp dx, 1024
        jb .c3
        mov ax, 0xFFFF
        jmp .c4
.c3:    mov cl, 10
        shr ax, cl
        mov cl, 6
        shl dx, cl
        or ax, dx
.c4:    mov [cs:ck_bs], ax
        mov byte [cs:ck_ok], 1
        pop bx
        pop dx
        jmp .l
.d:     mov [cs:ck_rp], bx
        ret

; ---------------------------------------------------------------------------------------------
ck_apply:
        mov ax, MENU_SEG
        mov es, ax
        xor al, al                ; wanted: bit 0 = taps, bit 1 = LFOs
        cmp byte [cs:ck_ok], 0
        je .w
        mov ah, [cs:ck_on]
        cmp byte [cs:par + 11], 64
        jb .c
        mov ah, 1
.c:     or ah, ah
        jz .w
        mov al, 1
        cmp byte [cs:ck_lfo], 0
        je .w
        mov al, 3
.w:     mov ah, al
        xchg ah, [cs:ck_was]
        mov dl, al                ; a part turned off: TIME / RATE as the page has them
        not dl
        and dl, ah
        jz .k
        mov byte [es:LO_keepph], 1
        LOCALL LO_fx_apply
        mov byte [es:LO_keepph], 0
        mov byte [cs:ck_dirty], 1
.k:     or al, al
        jz .r
        mov [cs:ck_m], al
        mov al, [cs:ck_bpm + 0]   ; live reverse tempo (41-240), not when FREE
        cmp byte [cs:lr_bpm], 0
        je .t
        cmp al, 41
        jae .b1
        mov al, 41
.b1:    cmp byte [cs:ck_bpm + 1], 0
        jne .b2
        cmp al, 240
        jbe .b3
.b2:    mov al, 240
.b3:    mov [cs:lr_bpm], al
.t:     mov bl, [es:LO_fxon]      ; si = the preset's record (hi copy)
        xor bh, bh
        shl bx, 1
        mov si, [cs:preset_ptrs + bx]
        sub si, LOREL
        mov cl, [cs:si + 9]       ; nst
        mov ch, [cs:si + 10]      ; nmod
        add si, 11
        or ch, ch
        jnz .lfo
        or cl, cl
        jz .r
        cmp cl, 6
        ja .r
        mov ax, [cs:si + 3]       ; the first tap: >= 100 ms (not RESO's comb)
        cmp ax, 4410
        jb .r
        mov bx, ax
        mov ax, [cs:ck_bs]
        call ck_fold              ; ax = the note value near bx
        mov di, ax
        ; only when something changed: the target, the type, or a page edit (fx_apply put TIME's lengths back):
        ; the chip sees no writes at all while the tempo holds
        mov ax, di                ; within 0.4 % of the last target: keep it (the bar-to-bar jitter)
        sub ax, [cs:ck_last]
        jns .h1
        neg ax
.h1:    mov dx, di
        shr dx, 8
        cmp ax, dx
        ja .h2
        mov di, [cs:ck_last]
.h2:    push si
        push di
        mov si, ck_last
        mov dx, di
        call ck_chg
        mov dl, [es:LO_fxon]
        xor dh, dh
        call ck_chg
        mov dx, [es:LO_ptime]
        call ck_chg
        mov dx, [es:LO_pfb]
        call ck_chg
        mov dx, [es:LO_prate]
        call ck_chg
        pop di
        pop si
        cmp byte [cs:ck_dirty], 0
        je .r
        mov byte [cs:ck_dirty], 0
        xor ch, ch
.tp:    push cx
        mov ax, [cs:si + 3]       ; d x target / d0, rounded
        mul di
        cmp dx, bx
        jb .t1
        mov ax, 65534
        jmp .t2
.t1:    push bx
        shr bx, 1
        add ax, bx
        adc dx, 0
        pop bx
        div bx
.t2:    cmp ax, 2
        jae .t3
        mov ax, 2
.t3:    mov cx, ax
        mov al, [cs:si]
        mov ah, 0x0A
        out 0x80, ax
        mov ax, 2
        sub ax, cx
        out 0x84, ax
        pop cx
        add si, 5
        loop .tp
.r:     ret
.lfo:   test byte [cs:ck_m], 2
        jz .r
        mov al, 5                 ; slot 0's record
        mul cl
        add si, ax
        mov bx, [cs:si + 9]       ; its inc (preset)
        or bx, bx
        jz .r
        cmp bx, 256
        jae .r
        mov cl, 8
        shl bx, cl                ; 8.8
        mov cx, [cs:ck_dt]        ; target inc: a lap a bar (dt ticks) -> 2^24 / dt, 8.8
        mov dx, 0x0100
        xor ax, ax
        cmp cx, 0x0101
        jb .r
        div cx
        call ck_fold              ; ax = target (8.8) folded near bx
        mov di, ax
        mov bp, LO_mslots
        xor ch, ch
        mov cl, [es:LO_nmods]
        jcxz .r
.ls:    test byte [cs:si + 2], 0x80   ; (saw slots: their rate is their pitch)
        jnz .ln
        mov ax, [cs:si + 9]       ; inc x target / inc0, rounded
        mul di
        push bx
        shr bx, 1
        add ax, bx
        adc dx, 0
        pop bx
        cmp dx, bx
        jae .ln
        div bx
        mov [es:bp + 9], ax
.ln:    add si, 13
        add bp, 16
        loop .ls
        ret

; [cs:si] vs dx: differ = store, ck_dirty; si += 2
ck_chg: cmp [cs:si], dx
        je .s
        mov [cs:si], dx
        mov byte [cs:ck_dirty], 1
.s:     add si, 2
        ret

; ax = a length, bx = the one wanted near: halve / double ax until it is within 0.71-1.41 x bx
ck_fold:
        push cx
        push dx
        mov cx, 12
.u:     push ax                   ; > 1.41 x bx: halve
        mov ax, bx
        mov dx, 362
        mul dx
        mov al, ah
        mov ah, dl                ; bx x 362 / 256
        or dh, dh
        jz .u1
        mov ax, 0xFFFF
.u1:    mov dx, ax
        pop ax
        cmp ax, dx
        jbe .d
        shr ax, 1
        loop .u
.d:     mov cx, 12
.d1:    push ax                   ; < 0.71 x bx: double
        mov ax, bx
        mov dx, 181
        mul dx
        mov al, ah
        mov ah, dl
        mov dx, ax
        pop ax
        cmp ax, dx
        jae .x
        test ah, 0x80
        jnz .x
        shl ax, 1
        loop .d1
.x:     pop dx
        pop cx
        ret

; ---------------------------------------------------------------------------------------------
; LOOPER freeze
fz_run:
        mov ax, MENU_SEG
        mov es, ax
        xor al, al
        cmp byte [es:LO_fxon], FXI_LOOPER
        jne .w
        cmp word [es:LO_pfb], 100
        jae .on
        cmp byte [cs:par + 10], 64
        jb .w
        mov al, 2                 ; (2: by CC 30: the FB tap is ours to set)
        jmp .w
.on:    mov al, 1
.w:     mov ah, [cs:fz_act]
        cmp al, ah
        je .r
        mov [cs:fz_act], al
        or ah, ah
        jnz .off
        mov ax, [es:LO_fxsendv]   ; on: note-ons get send 0, the sounding voices too
        mov [cs:fz_sv], ax
        mov word [es:LO_fxsendv], 0
        mov cx, NVOICE
        mov bx, 0x0700
        pushf
        cli
.v:     mov ax, bx
        out 0x80, ax
        xor ax, ax
        out 0x84, ax
        inc bx
        loop .v
        popf
.r:     cmp byte [cs:fz_act], 2   ; by CC 30: the loop's feedback tap (LOOPER: fn 3) at 1.0, every pass
        jne .x
        mov ax, 0x0A03
        out 0x80, ax
        mov ax, 0x7FFF
        out 0x82, ax
.x:     ret
.off:   or al, al                 ; (1 <-> 2: stays frozen)
        jnz .r
        mov ax, [cs:fz_sv]
        mov [es:LO_fxsendv], ax
        mov byte [es:LO_keepph], 1
        LOCALL LO_fx_apply        ; FB tap back to the page's FB
        mov byte [es:LO_keepph], 0
        mov byte [cs:ck_dirty], 1 ; (and TIME's lengths: a synced loop gets the tempo's again)
        ret

; mfx_run: bx = the input voices' send word: none while frozen
fz_in:  cmp byte [cs:fz_act], 0
        je .r
        xor bx, bx
.r:     ret

; ---------------------------------------------------------------------------------------------
; LO-FI on the 2 x lr_m frames lr_fill just wrote at lr_wb (ES = CS): the top lf_bits bits of every sample, and
; with lf_sh > 1 one frame in lf_sh held for the next ones (sample-and-hold: 44.1 kHz / lf_sh, unfiltered = aliasing,
; the point). Both sides (L = what you hear dry, R = the wet; with feedback the history takes them crushed).
lf_run:
        mov cl, 16
        sub cl, [cs:lf_bits]
        jns .b
        xor cl, cl
.b:     cmp byte [cs:lf_sh], 1
        ja .go
        or cl, cl
        jz .r
.go:    mov ax, 0xFFFF
        shl ax, cl
        mov di, [cs:lr_wb]
        mov cx, [cs:lr_m]
        shl cx, 1
        cmp byte [cs:lf_sh], 1
        ja .sh
.m:     and [es:di], ax
        and [es:di + 2], ax
        add di, 4
        loop .m
.r:     ret
.sh:    mov bl, [cs:lf_sh]
        xor bh, bh
        dec bx
        mov si, bx
        mov bp, [cs:lf_c]
        mov bx, [cs:lf_hl]
        mov dx, [cs:lf_hr]
.s:     dec bp
        jns .h
        mov bp, si
        mov bx, [es:di]
        and bx, ax
        mov dx, [es:di + 2]
        and dx, ax
.h:     mov [es:di], bx
        mov [es:di + 2], dx
        add di, 4
        loop .s
        mov [cs:lf_c], bp
        mov [cs:lf_hl], bx
        mov [cs:lf_hr], dx
        ret

ck_rp:    dw 0
ck_now:   dw 0
ck_lb:    db 0
ck_lt:    dw 0
ck_t0:    dw 0
ck_dt:    dw 3914             ; OS ticks a bar
ck_bpm:   dw 120
ck_bs:    dw 22050
ck_n:     db 0
ck_ok:    db 0
ck_was:   db 0
ck_m:     db 0
ck_dirty: db 1
ck_last:  times 5 dw 0xFFFF       ; target, type, TIME, FB, RATE as last written (fx_apply ran)
fz_act:   db 0
fz_sv:    dw 0
lf_c:     dw 0
lf_hl:    dw 0
lf_hr:    dw 0
