; CHOP (0.28): the SYNTH page's second mode (MULTI -> < CHOP > GO). Slices the current sample (the one the sample
; pages last selected, between its START and END) into new samples + a ready-to-play program, one slice per key from
; C3 up, each at its own pitch (one-shot). Ported from the s2k CFW's chop tool. Included by rosetta_hi.asm.
;   EQUAL  2-64 equal slices
;   TRANS  cuts at transients, sensitivity 1-9 (256-word blocks of mean |x|: a block louder than the last one by
;          ratio (26 - 2 x SENS) / 8 over a floor, at least 8 blocks after the last cut, cut half a block early)
;   LAZY   F2 on GO plays the sample (PLAY, as on the sample page), F2 taps a cut on each hit, F1 stops (or the
;          sample ends); then F2 makes them
; Cuts snap to the nearest zero crossing (+-128 words). Result: samples "NAME    -01".., program "NAME    CHOP"
; with the next free program number.
; Page: line 1 "CHP" + the sample's name; line 2 ">EQUAL 16    >GO": F1 / F2 = cursor (F2 on GO = GO, twice),
; wheel / GROUP = the value under the cursor. Messages stay on line 2 until the next key.
; Work RAM: CH_SEG = 4A00:0000-36FF (lin 4A000-4D6FF), inside the live-reverse history, which only runs on the
; SAMPLE page; DS = CH_SEG while the engine runs.
CH_SEG          equ 0x4A00
CH_CTX_SYN      equ 2               ; the menu code's ctx on the SYNTH page (src/rosetta_prog.asm CTX_SYN)
W_CUR_HSEG      equ 0x0050      ; header segment of the sample
W_LOC           equ 0x0052      ; dword: its data address (words)
W_LEN           equ 0x0056      ; dword: its length
W_TMP           equ 0x00C0      ; scratch (32 bytes)
W_NMK           equ 0x0160      ; word: marks (slices + 1)
W_NEWHDR        equ 0x0164      ; word: transient floor
W_NAMEBUF       equ 0x0170      ; 12 bytes: the base name
W_T0            equ 0x0180      ; word: OS ticks since the lazy capture started
W_RATE          equ 0x0182      ; word: the sample's rate
W_VOICE         equ 0x0184      ; byte: voice playing it (FFh none yet, FEh: positions unreadable)
W_VFIRST        equ 0x0186      ; dword: its first position seen
W_VFT0          equ 0x018A      ; word: W_T0 then
W_RAWKEY        equ 0x018C      ; byte: last raw F2 state
W_RAWT          equ 0x018E      ; word: time of the last tap
W_LASTT         equ 0x0190      ; byte: OS tick last pass
W_BUF           equ 0x1000      ; sample I/O buffer, 4096 words
BUF_WORDS       equ 0x1000
W_MARKS         equ 0x3000      ; dwords
W_SLSEG         equ 0x3400      ; word[MAX_SLICES]
W_KGSEG         equ 0x3500
W_VSNAP         equ 0x3600      ; dword[32]
MAX_SLICES      equ 64
SH_PITCH        equ 0x02
SH_NAME         equ 0x03
SH_NLOOPS       equ 0x10
SH_PTYPE        equ 0x13
SH_LOC          equ 0x16
SH_LEN          equ 0x1A
SH_START        equ 0x1E
SH_END          equ 0x22
SH_LOOP1        equ 0x26
SH_PARTNER      equ 0x88
SH_RATE         equ 0x8A
NUM_PROGS       equ 0x74F4
NUM_SAMPS       equ 0x74F6
CATALOG         equ 0xB0D0
CUR_SAMPLE      equ 0x7639
MEM_TOTAL       equ 0x7539
MEM_NEXT        equ 0x753D
MEM_FREE        equ 0x7541
SADDR           equ 0x78E4

; ---------------------------------------------------------------------------------------------
; UI (from syn_ui, DS = 0, ES free). Keys al: 0 F1, 1 F2, 4/5 PAGE, 6/7 GROUP, 8/9 rocker
ch_key: mov word [cs:ch_msg], 0
        cmp byte [cs:ch_lazy], 1
        jne .nc
        cmp al, 0                 ; capturing: F1 stops (F2 taps come from the matrix, ch_tick)
        jne .r
        jmp ch_lzstop
.nc:    cmp al, 6
        je .dn
        cmp al, 7
        je .up
        cmp al, 0
        je .left
        cmp al, 8
        je .left
        cmp al, 9
        je .right
        cmp al, 1
        jne .r
        cmp byte [cs:ch_cur], 2
        je ch_go
.right: mov byte [cs:ch_arm], 0
        cmp byte [cs:ch_cur], 2
        jae .r
        inc byte [cs:ch_cur]
        ret
.left:  mov byte [cs:ch_arm], 0
        cmp byte [cs:ch_cur], 0
        je .r
        dec byte [cs:ch_cur]
.r:     ret
.dn:    mov al, -1
        jmp ch_step
.up:    mov al, 1
        ; fall through
; value step al
ch_step:
        cmp byte [cs:ch_lazy], 1
        je .r
        mov word [cs:ch_msg], 0
        mov byte [cs:ch_arm], 0
        mov byte [cs:ch_lazy], 0
        cmp byte [cs:ch_cur], 1
        ja .r
        je .val
        add al, [cs:ch_mode]
        cmp al, 2
        ja .r
        mov [cs:ch_mode], al
        ret
.val:   cmp byte [cs:ch_mode], 1
        je .sens
        ja .r
        add al, [cs:ch_n]
        cmp al, 2
        jl .r
        cmp al, MAX_SLICES
        jg .r
        mov [cs:ch_n], al
        ret
.sens:  add al, [cs:ch_sens]
        cmp al, 1
        jl .r
        cmp al, 9
        jg .r
        mov [cs:ch_sens], al
.r:     ret

; F2 on GO
ch_go:  push ds
        mov ax, CH_SEG
        mov ds, ax
        call ch_info
        jc .nos
        cmp byte [cs:ch_arm], 0
        jne .make
        cmp byte [cs:ch_mode], 2
        jne .calc
        cmp byte [cs:ch_lazy], 2
        je .ask                   ; taps captured: ask, then make
        call lazy_start
        jmp .x
.calc:  mov si, t_busy
        call ch_say
        cmp byte [cs:ch_mode], 0
        jne .tr
        call marks_equal
        jmp .ask
.tr:    call marks_transient
.ask:   cmp word [W_NMK], 2
        jb .none
        mov byte [cs:ch_arm], 1   ; "16 SLICES? F2"
        mov word [cs:ch_msg], t_slq
        jmp .x
.none:  mov word [cs:ch_msg], t_noslice
        mov byte [cs:ch_lazy], 0
        jmp .x
.make:  mov byte [cs:ch_arm], 0
        mov byte [cs:ch_lazy], 0
        mov si, t_busy
        call ch_say
        mov byte [cs:ch_busy], 1  ; (hi_tick idles while the OS's busy loop runs)
        call snap_marks
        call make_slices          ; si = the result
        mov byte [cs:ch_busy], 0
        mov [cs:ch_msg], si
        jmp .x
.nos:   mov word [cs:ch_msg], t_nosmp
.x:     pop ds
        ret

; fxbuf <- the page (es = MENU_SEG, di = LO_fxbuf, cleared by sy_draw)
ch_draw:
        push ds
        mov di, LO_fxbuf
        mov word [es:di], 'CH'
        mov byte [es:di + 2], 'P'
        push ds
        mov ax, CH_SEG
        mov ds, ax
        call ch_info
        pop ds
        mov si, t_nosmp
        jc .nm
        push ds                   ; the sample's name (Akai chars)
        mov ds, [cs:ch_hseg]
        mov si, SH_NAME
        mov di, LO_fxbuf + 4
        mov cx, 12
.c:     lodsb
        mov bx, sy_akai
        cmp al, 41
        jb .ok
        mov al, 10
.ok:    cs xlatb
        mov [es:di], al
        inc di
        loop .c
        pop ds
        jmp .l2
.nm:    mov di, LO_fxbuf + 4
        mov cx, 12
        call sy_cpy
.l2:    mov si, [cs:ch_msg]
        or si, si
        jz .fl
        mov di, LO_fxbuf + 16
        mov cx, 16
        call sy_cpy
        cmp si, t_slq + 16        ; "nn SLICES?": the count
        jne .r
        push ds
        mov ax, CH_SEG
        mov ds, ax
        mov ax, [W_NMK]
        pop ds
        dec ax
        mov di, LO_fxbuf + 16
        call sy_d3
        jmp .r
.fl:    cmp byte [cs:ch_lazy], 1
        jne .f
        mov si, t_lazy            ; "TAP F2  CUTS nnn"
        mov di, LO_fxbuf + 16
        mov cx, 16
        call sy_cpy
        push ds
        mov ax, CH_SEG
        mov ds, ax
        mov ax, [W_NMK]
        pop ds
        dec ax
        mov di, LO_fxbuf + 29
        call sy_d3
        jmp .r
.f:     mov al, [cs:ch_mode]      ; ">EQUAL >16    >GO"
        mov ah, 5
        mul ah
        add ax, t_modes
        mov si, ax
        mov di, LO_fxbuf + 17
        mov cx, 5
        call sy_cpy
        mov al, [cs:ch_n]
        cmp byte [cs:ch_mode], 1
        jb .v
        mov al, [cs:ch_sens]
        je .v
        mov word [es:LO_fxbuf + 24], '--'
        jmp .g
.v:     xor ah, ah
        mov di, LO_fxbuf + 23
        call sy_d3
.g:     mov word [es:LO_fxbuf + 30], 'GO'
        mov al, [cs:ch_cur]       ; the cursor: col 16 / 22 / 29
        mov bx, LO_fxbuf + 16
        cmp al, 1
        jb .m
        mov bx, LO_fxbuf + 22
        je .m
        mov bx, LO_fxbuf + 29
.m:     mov byte [es:bx], '>'
.r:     pop ds
        ret

; cs:si (16 chars) on line 2 at once (the LCD while we work)
ch_say: push es
        push ds
        push si
        mov ax, MENU_SEG
        mov es, ax
        xor ax, ax
        mov ds, ax
        mov di, LO_fxbuf + 16
        mov cx, 16
        call sy_cpy
        call 0x3EA0:0x0027
        pop si
        pop ds
        pop es
        ret

; every main-loop tick (hi_tick, DS = 0): the lazy capture
ch_tick:
        cmp byte [cs:ch_lazy], 1
        jne .r
        push ds
        mov ax, CH_SEG
        mov ds, ax
        push es
        mov ax, MENU_SEG          ; left the CHOP page: stop
        mov es, ax
        cmp byte [es:LO_ctx], CH_CTX_SYN
        pop es
        jne .stp
        cmp byte [cs:sy_lvl], 1
        jne .stp
        cmp byte [cs:sy_mode], 1
        jne .stp
        push ds
        xor ax, ax
        mov ds, ax
        mov al, [0x73DA]
        pop ds
        mov ah, al
        sub al, [W_LASTT]
        mov [W_LASTT], ah
        xor ah, ah
        add [W_T0], ax
        pushf                     ; F2 straight from the matrix (row 5, column bit 1, low = down): the tap's
        cli                       ; time to the pass, past the OS's key-repeat lockout (no scan in between)
        mov al, 0xDF
        out 0x52, al
        nop
        nop
        in al, 0x50
        popf
        not al
        and al, 2
        mov ah, [W_RAWKEY]
        mov [W_RAWKEY], al
        cmp al, ah
        je .ne
        or al, al
        jz .ne
        mov ax, [W_T0]            ; debounce 25 ms
        sub ax, [W_RAWT]
        cmp ax, 50
        jb .ne
        mov ax, [W_T0]
        mov [W_RAWT], ax
        call lazy_tap
        call ch_redraw
.ne:    call lazy_now             ; past END: stop
        cmp dx, [W_TMP + 12]
        jb .x
        ja .stp
        cmp ax, [W_TMP + 10]
        jb .x
.stp:   call lazy_stop
        call ch_redraw
.x:     pop ds
.r:     ret

ch_lzstop:
        push ds
        mov ax, CH_SEG
        mov ds, ax
        call lazy_stop
        pop ds
        ret

ch_redraw:
        push es
        push ds
        pusha
        xor ax, ax
        mov ds, ax
        call sy_draw
        call 0x3EA0:0x0027
        popa
        pop ds
        pop es
        ret

; ---------------------------------------------------------------------------------------------
; the current sample: W_CUR_HSEG / W_LOC / W_LEN (DS = CH_SEG). CF = 1: none
ch_info:
        push ax
        push bx
        push es
        xor ax, ax
        mov es, ax
        mov bx, [es:CUR_SAMPLE]
        cmp bx, [es:NUM_SAMPS]
        jae .bad
        mov al, [es:NUM_PROGS]    ; (a byte: 74F5 is something else)
        xor ah, ah
        add bx, ax
        shl bx, 1
        mov ax, [es:bx + CATALOG]
        mov [W_CUR_HSEG], ax
        mov [cs:ch_hseg], ax
        mov es, ax
        cmp byte [es:0], 3
        jne .bad
        mov ax, [es:SH_LOC]
        mov [W_LOC], ax
        mov ax, [es:SH_LOC + 2]
        mov [W_LOC + 2], ax
        mov ax, [es:SH_LEN]
        mov [W_LEN], ax
        mov ax, [es:SH_LEN + 2]
        mov [W_LEN + 2], ax
        or ax, [W_LEN]
        jz .bad
        pop es
        pop bx
        pop ax
        clc
        ret
.bad:   pop es
        pop bx
        pop ax
        stc
        ret

; ---------------------------------------------------------------------------------------------
; OS bridges (DS = CH_SEG on entry, kept)
ch_osnear:                        ; near OS routine at 0FE4:bx, DS = ES = 0
        push ds
        push es
        xor ax, ax
        mov ds, ax
        mov es, ax
        push cs
        push word .back
        push word RETF_0FE4
        push word 0x0FE4
        push bx
        retf
.back:  pop es
        pop ds
        ret
ch_bg:  pusha                     ; voices / MIDI alive while we work (0FE4:018A)
        mov bx, 0x018A
        call ch_osnear
        popa
        ret
sread:  pusha                     ; cx words at offset dx:ax of the sample -> W_BUF
        add ax, [W_LOC]
        adc dx, [W_LOC + 2]
        jmp sread_go
sread_abs:
        pusha
sread_go:
        push es
        push ds
        xor bx, bx
        mov es, bx
        mov [es:SADDR], ax
        mov [es:SADDR + 2], dx
        mov dx, CH_SEG
        mov di, W_BUF
        xor bx, bx
        mov ds, bx
        call 0x2345:0x1AA0
        pop ds
        pop es
        popa
        ret
swrite_abs:                       ; cx words from W_BUF -> absolute dx:ax
        pusha
        push es
        push ds
        xor bx, bx
        mov es, bx
        mov [es:SADDR], ax
        mov [es:SADDR + 2], dx
        mov dx, CH_SEG
        mov si, W_BUF
        xor bx, bx
        mov ds, bx
        call 0x2345:0x1AC8
        pop ds
        pop es
        popa
        ret
audition:                         ; al = 2Dh PLAY down / 2Eh up, as on the sample page (MODE 5 for the call)
        pusha
        push ds
        push es
        xor bx, bx
        mov ds, bx
        mov es, bx
        mov bl, [0x762B]
        push bx
        mov byte [0x762B], 5
        cmp al, 0x2D
        jne .up
        call 0x0FE4:0x034F
        jmp .x
.up:    call 0x0FE4:0x0353
.x:     pop bx
        mov [0x762B], bl
        pop es
        pop ds
        popa
        ret

; dx:ax = dx:ax * cx (low 32)
mul32x16:
        push bx
        push si
        mov si, dx
        mul cx
        mov bx, ax
        mov ax, si
        push dx
        mul cx
        pop dx
        add dx, ax
        mov ax, bx
        pop si
        pop bx
        ret
; dx:ax = dx:ax / cx, remainder in bx
div32x16:
        push si
        mov si, ax
        mov ax, dx
        xor dx, dx
        div cx
        mov bx, ax
        mov ax, si
        div cx
        xchg bx, dx
        pop si
        ret
; dx:ax >>= cx
shr32:  jcxz .x
        push cx
.l:     shr dx, 1
        rcr ax, 1
        loop .l
        pop cx
.x:     ret

; ---------------------------------------------------------------------------------------------
; marks: W_MARKS[0..n-1] = cuts (offsets in the sample), first = START, last = END; W_NMK = n
get_region:                       ; bx:cx = START, di:si = END (exclusive, at most the length)
        push es
        push ax
        mov es, [W_CUR_HSEG]
        mov cx, [es:SH_START]
        mov bx, [es:SH_START + 2]
        mov si, [es:SH_END]
        mov di, [es:SH_END + 2]
        add si, 1
        adc di, 0
        cmp di, [W_LEN + 2]
        jb .ok
        ja .cl
        cmp si, [W_LEN]
        jbe .ok
.cl:    mov si, [W_LEN]
        mov di, [W_LEN + 2]
.ok:    pop ax
        pop es
        ret

mark_store:                       ; dx:ax -> W_MARKS[W_NMK++], unless < the last + 64
        push bx
        push cx
        push si
        mov bx, [W_NMK]
        cmp bx, MAX_SLICES + 1
        jae .x
        shl bx, 2
        test bx, bx
        jz .put
        mov cx, [bx + W_MARKS - 4]
        mov si, [bx + W_MARKS - 2]
        add cx, 64
        adc si, 0
        cmp dx, si
        ja .put
        jb .x
        cmp ax, cx
        jb .x
.put:   mov [bx + W_MARKS], ax
        mov [bx + W_MARKS + 2], dx
        inc word [W_NMK]
.x:     pop si
        pop cx
        pop bx
        ret

mark_store_end:                   ; the last cut: moves the previous one if too close
        push bx
        call mark_store
        mov bx, [W_NMK]
        dec bx
        shl bx, 2
        cmp [bx + W_MARKS], ax
        jne .rep
        cmp [bx + W_MARKS + 2], dx
        je .x
.rep:   cmp word [W_NMK], 1
        jbe .add
        mov [bx + W_MARKS], ax
        mov [bx + W_MARKS + 2], dx
        jmp .x
.add:   mov [bx + W_MARKS + 4], ax
        mov [bx + W_MARKS + 6], dx
        inc word [W_NMK]
.x:     pop bx
        ret

marks_equal:
        pusha
        mov word [W_NMK], 0
        call get_region
        sub si, cx                ; L = END - START
        sbb di, bx
        mov [W_TMP + 10], si
        mov [W_TMP + 12], di
        mov [W_TMP + 4], cx
        mov [W_TMP + 6], bx
        xor bp, bp
.l:     mov ax, [W_TMP + 10]      ; START + L x i / N
        mov dx, [W_TMP + 12]
        mov cx, bp
        call mul32x16
        mov cl, [cs:ch_n]
        xor ch, ch
        call div32x16
        add ax, [W_TMP + 4]
        adc dx, [W_TMP + 6]
        call mark_store
        inc bp
        mov al, [cs:ch_n]
        xor ah, ah
        cmp bp, ax
        jbe .l
        popa
        ret

TBLOCK  equ 256
marks_transient:
        pusha
        mov word [W_NMK], 0
        call get_region
        mov [W_TMP + 10], si
        mov [W_TMP + 12], di
        mov ax, cx
        mov dx, bx
        call mark_store
        mov word [W_TMP + 8], 0
        mov word [W_TMP + 0], 0
        mov al, [cs:ch_sens]      ; ratio8 = 26 - 2 SENS, floor = 40 + (9 - SENS) x 40
        xor ah, ah
        shl ax, 1
        mov cx, 26
        sub cx, ax
        mov [W_TMP + 14], cx
        mov al, 9
        sub al, [cs:ch_sens]
        mov ah, 40
        mul ah
        add ax, 40
        mov [W_NEWHDR], ax
        mov ax, [W_MARKS]
        mov dx, [W_MARKS + 2]
.chunk: mov cx, [W_TMP + 10]
        mov bx, [W_TMP + 12]
        sub cx, ax
        sbb bx, dx
        jb .done
        test bx, bx
        jnz .big
        cmp cx, TBLOCK
        jb .done
        cmp cx, BUF_WORDS
        jbe .rd
.big:   mov cx, BUF_WORDS
.rd:    and cx, ~(TBLOCK - 1)
        call sread
        push ax
        push dx
        mov si, W_BUF
        mov di, cx
        shr di, 8
.blk:   push di
        push ax
        push dx
        xor bx, bx
        xor bp, bp
        mov cx, TBLOCK
.s:     lodsw
        test ax, ax
        jns .ab
        neg ax
        jns .ab
        mov ax, 0x7FFF
.ab:    add bx, ax
        adc bp, 0
        loop .s
        mov ax, bx
        mov dx, bp
        mov cx, 8
        call shr32
        mov bx, ax
        pop dx
        pop ax
        inc word [W_TMP + 0]
        jnz .g
        dec word [W_TMP + 0]
.g:     push ax
        push dx
        mov ax, [W_TMP + 8]
        mul word [W_TMP + 14]
        mov cx, [W_NEWHDR]
        shl cx, 3
        add ax, cx
        adc dx, 0
        mov cx, bx
        push bx
        xor bx, bx
        shl cx, 1
        rcl bx, 1
        shl cx, 1
        rcl bx, 1
        shl cx, 1
        rcl bx, 1
        cmp bx, dx
        ja .on
        jb .off
        cmp cx, ax
        jbe .off
.on:    pop bx
        cmp word [W_TMP + 0], 8
        jb .off2
        pop dx
        pop ax
        push ax
        push dx
        push si
        sub si, W_BUF + TBLOCK * 2 + TBLOCK
        sar si, 1
        add ax, si
        adc dx, 0
        test si, si
        jns .pos
        dec dx
.pos:   pop si
        call mark_store
        mov word [W_TMP + 0], 0
        jmp .off2
.off:   pop bx
.off2:  pop dx
        pop ax
        mov [W_TMP + 8], bx
        pop di
        dec di
        jnz .blk
        pop dx
        pop ax
        mov cx, si
        sub cx, W_BUF
        shr cx, 1
        add ax, cx
        adc dx, 0
        cmp word [W_NMK], MAX_SLICES
        jae .done
        call ch_bg
        jmp .chunk
.done:  mov ax, [W_TMP + 10]
        mov dx, [W_TMP + 12]
        call mark_store_end
        popa
        ret

; every inner cut to the nearest zero crossing within +-128 words
snap_marks:
        pusha
        mov bp, 1
.l:     mov ax, [W_NMK]
        dec ax
        cmp bp, ax
        jae .x
        mov bx, bp
        shl bx, 2
        mov ax, [bx + W_MARKS]
        mov dx, [bx + W_MARKS + 2]
        sub ax, 128
        sbb dx, 0
        jb .n
        mov cx, 256
        call sread
        mov di, 0
.s:     mov si, 128
        add si, di
        call .zc
        jnc .f
        mov si, 128
        sub si, di
        call .zc
        jnc .f
        inc di
        cmp di, 127
        jb .s
        jmp .n
.f:     add ax, si
        adc dx, 0
        mov [bx + W_MARKS], ax
        mov [bx + W_MARKS + 2], dx
.n:     inc bp
        jmp .l
.x:     popa
        ret
.zc:    push ax                   ; CF = 0: W_BUF[si - 1], W_BUF[si] change sign
        push si
        shl si, 1
        mov ax, [si + W_BUF - 2]
        xor ax, [si + W_BUF]
        js .yes
        cmp word [si + W_BUF], 0
        je .yes
        pop si
        pop ax
        stc
        ret
.yes:   pop si
        pop ax
        clc
        ret

; ---------------------------------------------------------------------------------------------
; LAZY
lazy_start:
        pusha
        call get_region
        mov [W_TMP + 10], si
        mov [W_TMP + 12], di
        mov word [W_NMK], 0
        mov ax, cx
        mov dx, bx
        call mark_store
        push es
        mov es, [W_CUR_HSEG]
        mov ax, [es:SH_RATE]
        pop es
        test ax, ax
        jnz .r
        mov ax, 44100
.r:     mov [W_RATE], ax
        call voices_snapshot
        mov byte [W_VOICE], 0xFF
        push ds
        xor ax, ax
        mov ds, ax
        mov al, [0x73DA]
        pop ds
        mov [W_LASTT], al
        mov word [W_T0], 0
        mov byte [W_RAWKEY], 2    ; F2 (GO) is still down: wait for a fresh press
        mov word [W_RAWT], 0
        mov al, 0x2D
        call audition
        mov byte [cs:ch_lazy], 1
        popa
        ret

lazy_stop:
        mov al, 0x2E
        call audition
        push ax
        push dx
        mov ax, [W_TMP + 10]
        mov dx, [W_TMP + 12]
        call mark_store_end
        pop dx
        pop ax
        mov byte [cs:ch_lazy], 2
        mov byte [cs:ch_arm], 0
        mov word [cs:ch_msg], 0
        mov byte [cs:ch_cur], 2
        ret

lazy_tap:
        pusha
        call lazy_now
        mov bx, [W_NMK]           ; after the last cut + 64, before END
        dec bx
        shl bx, 2
        mov cx, [bx + W_MARKS]
        mov bx, [bx + W_MARKS + 2]
        add cx, 64
        adc bx, 0
        cmp dx, bx
        jb .x
        ja .ok
        cmp ax, cx
        jb .x
.ok:    cmp dx, [W_TMP + 12]
        ja .x
        jb .st
        cmp ax, [W_TMP + 10]
        jae .x
.st:    cmp word [W_NMK], MAX_SLICES
        jae .x
        call mark_store
.x:     popa
        ret

; where it plays now: the voice's position if it can be read and moves, else START + time x rate
lazy_now:
        push bx
        push cx
        cmp byte [W_VOICE], 0xFE
        je .time
        mov bl, [W_VOICE]
        call voice_find_pos
        jc .time
        cmp bl, 0xFF
        jne .seen
        mov [W_VFIRST], ax
        mov [W_VFIRST + 2], dx
        mov cx, [W_T0]
        mov [W_VFT0], cx
        jmp .x
.seen:  cmp ax, [W_VFIRST]
        jne .x
        cmp dx, [W_VFIRST + 2]
        jne .x
        mov cx, [W_T0]
        sub cx, [W_VFT0]
        cmp cx, 80                ; 40 ms on the first position: unreadable, time from now on
        jb .x
        mov byte [W_VOICE], 0xFE
.time:  mov ax, [W_T0]            ; START + ticks x rate / 1957 (OS ticks a second)
        mov cx, [W_RATE]
        mul cx
        mov cx, 1957
        call div32x16
        add ax, [W_MARKS]
        adc dx, [W_MARKS + 2]
.x:     pop cx
        pop bx
        ret

voice_pos:                        ; voice bl's reg 0 (MAME layout: the position) -> dx:ax, word address
        push cx
        push bx
        pushf
        cli
        mov al, bl
        xor ah, ah
        out 0x80, ax
        in ax, 0x84
        mov cx, ax
        in ax, 0x86
        mov dx, ax
        in ax, 0x82
        popf
        mov bx, ax
        and dx, 0x1F
        mov ax, cx
        push bx
        mov bx, dx
        xor dx, dx
        mov cx, 4
.sh:    shl ax, 1
        rcl dx, 1
        loop .sh
        mov cl, 4
        shl bx, cl
        or dx, bx
        pop bx
        mov cl, 12
        shr bx, cl
        or ax, bx
        pop bx
        pop cx
        ret

voices_snapshot:
        pusha
        mov bl, 1
.l:     call voice_pos
        xor bh, bh
        mov di, bx
        shl di, 2
        mov [di + W_VSNAP], ax
        mov [di + W_VSNAP + 2], dx
        inc bl
        cmp bl, 32
        jb .l
        popa
        ret

voice_find_pos:                   ; CF = 0: a voice that moved since the start and is inside the sample,
        push bx                   ; dx:ax = its offset in it
        push cx
        push di
        mov bl, [W_VOICE]
        cmp bl, 0xFF
        jne .chk1
        mov bl, 1
.scan:  call .try
        jnc .found
        inc bl
        cmp bl, 32
        jb .scan
        stc
        jmp .x
.chk1:  call .try
        jc .lost
.found: mov [W_VOICE], bl
        clc
        jmp .x
.lost:  mov byte [W_VOICE], 0xFF
        stc
.x:     pop di
        pop cx
        pop bx
        ret
.try:   call voice_pos
        xor bh, bh
        mov di, bx
        shl di, 2
        cmp ax, [di + W_VSNAP]
        jne .mv
        cmp dx, [di + W_VSNAP + 2]
        je .no
.mv:    sub ax, [W_LOC]
        sbb dx, [W_LOC + 2]
        jb .no
        cmp dx, [W_LEN + 2]
        jb .yes
        ja .no
        cmp ax, [W_LEN]
        jae .no
.yes:   clc
        ret
.no:    stc
        ret

; ---------------------------------------------------------------------------------------------
; build: samples + program + keygroups, then the OS rebuilds its lists. si = the result message (cs)
make_slices:
        push ax
        push bx
        push cx
        push dx
        push di
        push bp
        push es
        mov ax, [W_NMK]
        dec ax
        mov [W_TMP + 0], ax       ; N
        push ds                   ; free header slots: 2N + 1
        xor bx, bx
        mov ds, bx
        call 0x2345:0x151A        ; bp = free headers
        pop ds
        mov ax, [W_TMP + 0]
        shl ax, 1
        inc ax
        cmp bp, ax
        jae .hdrok
        mov si, t_nohdr
        jmp .ret
.hdrok: call slices_total         ; memory: the slices + 256 a slice
        push es
        xor bx, bx
        mov es, bx
        cmp dx, [es:MEM_FREE + 2]
        jb .memok0
        ja .nomem
        cmp ax, [es:MEM_FREE]
        jbe .memok0
.nomem: pop es
        mov si, t_nomem
        jmp .ret
.memok0:
        pop es
        push ds                   ; the base name
        pop es
        push ds
        mov ds, [W_CUR_HSEG]
        mov si, SH_NAME
        mov di, W_NAMEBUF
        mov cx, 12
        rep movsb
        pop ds
        xor bp, bp
.samp:  call make_one_slice
        jc .fail
        inc bp
        cmp bp, [W_TMP + 0]
        jb .samp
        call make_program
        jc .fail
        mov bx, 0x22F3            ; the OS rebuilds its catalogue
        call ch_osnear
        call reselect_sample
        mov si, t_made
        jmp .ret
.fail:  mov si, t_fail
.ret:   pop es
        pop bp
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

reselect_sample:                  ; the catalogue moved: CUR_SAMPLE on our sample again
        pusha
        push es
        xor ax, ax
        mov es, ax
        mov cx, [es:NUM_SAMPS]
        mov al, [es:NUM_PROGS]
        xor ah, ah
        mov si, ax
        shl si, 1
        add si, CATALOG
        xor bx, bx
        mov ax, [W_CUR_HSEG]
        jcxz .x
.l:     cmp [es:si], ax
        je .f
        add si, 2
        inc bx
        loop .l
        jmp .x
.f:     mov [es:CUR_SAMPLE], bx
.x:     pop es
        popa
        ret

slices_total:                     ; dx:ax = the slices' length + 256 a slice
        push bx
        push cx
        mov bx, [W_NMK]
        dec bx
        shl bx, 2
        mov ax, [bx + W_MARKS]
        mov dx, [bx + W_MARKS + 2]
        sub ax, [W_MARKS]
        sbb dx, [W_MARKS + 2]
        mov cx, [W_TMP + 0]
        mov ch, cl
        xor cl, cl
        add ax, cx
        adc dx, 0
        pop cx
        pop bx
        ret

make_one_slice:                   ; slice bp: memory, audio, header. CF = 1: failed
        pusha
        push es
        mov bx, bp
        shl bx, 2
        mov ax, [bx + W_MARKS + 4]
        mov dx, [bx + W_MARKS + 6]
        sub ax, [bx + W_MARKS]
        sbb dx, [bx + W_MARKS + 2]
        mov [W_TMP + 4], ax       ; len
        mov [W_TMP + 6], dx
        xor cx, cx
        mov es, cx
        mov ax, [es:MEM_NEXT]     ; dst = MEM_NEXT, 256-aligned
        mov dx, [es:MEM_NEXT + 2]
        add ax, 0xFF
        adc dx, 0
        xor al, al
        mov [W_TMP + 8], ax
        mov [W_TMP + 10], dx
        add ax, [W_TMP + 4]
        adc dx, [W_TMP + 6]
        mov [es:MEM_NEXT], ax
        mov [es:MEM_NEXT + 2], dx
        mov cx, [es:MEM_TOTAL]
        mov di, [es:MEM_TOTAL + 2]
        sub cx, ax
        sbb di, dx
        mov [es:MEM_FREE], cx
        mov [es:MEM_FREE + 2], di
        mov ax, [bx + W_MARKS]    ; src = W_LOC + mark
        mov dx, [bx + W_MARKS + 2]
        add ax, [W_LOC]
        adc dx, [W_LOC + 2]
        mov [W_TMP + 12], ax
        mov [W_TMP + 14], dx
        mov si, [W_TMP + 4]
        mov di, [W_TMP + 6]
.cp:    mov cx, si
        or cx, di
        jz .cpd
        mov cx, BUF_WORDS
        test di, di
        jnz .c1
        cmp si, cx
        jae .c1
        mov cx, si
.c1:    mov ax, [W_TMP + 12]
        mov dx, [W_TMP + 14]
        call sread_abs
        mov ax, [W_TMP + 8]
        mov dx, [W_TMP + 10]
        call swrite_abs
        add [W_TMP + 12], cx
        adc word [W_TMP + 14], 0
        add [W_TMP + 8], cx
        adc word [W_TMP + 10], 0
        sub si, cx
        sbb di, 0
        call ch_bg
        jmp .cp
.cpd:   mov ax, [W_TMP + 8]
        mov dx, [W_TMP + 10]
        sub ax, [W_TMP + 4]
        sbb dx, [W_TMP + 6]
        mov [W_TMP + 8], ax
        mov [W_TMP + 10], dx
        push ds
        xor ax, ax
        mov ds, ax
        call 0x2345:0x1535        ; es = a free header, CF: none
        pop ds
        jc .bad
        mov ax, es
        mov bx, bp
        shl bx, 1
        mov [bx + W_SLSEG], ax
        push ds                   ; the source's header
        mov ds, [W_CUR_HSEG]
        xor si, si
        xor di, di
        mov cx, 192
        rep movsb
        pop ds
        mov si, W_NAMEBUF         ; name = base[0..7] '-' nn ' '
        mov di, SH_NAME
        mov cx, 8
        rep movsb
        mov al, 39
        stosb
        mov ax, bp
        inc ax
        mov cl, 10
        div cl
        stosw
        mov al, 10
        stosb
        mov ax, [W_TMP + 8]
        mov [es:SH_LOC], ax
        mov ax, [W_TMP + 10]
        mov [es:SH_LOC + 2], ax
        mov ax, [W_TMP + 4]
        mov dx, [W_TMP + 6]
        mov [es:SH_LEN], ax
        mov [es:SH_LEN + 2], dx
        mov word [es:SH_START], 0
        mov word [es:SH_START + 2], 0
        mov [es:SH_END], ax       ; one past the last word (OS convention)
        mov [es:SH_END + 2], dx
        mov byte [es:SH_NLOOPS], 0
        mov byte [es:SH_NLOOPS + 1], 0
        mov byte [es:SH_PTYPE], 3 ; one-shot
        mov di, SH_LOOP1
        xor ax, ax
        mov cx, 6
        rep stosw
        mov word [es:SH_PARTNER], 0xFFFF
        call slice_note
        mov [es:SH_PITCH], al
        pop es
        popa
        clc
        ret
.bad:   pop es
        popa
        stc
        ret

slice_note:                       ; al = slice bp's key: C3 = 60 up (lower if N would pass 127)
        push bx
        mov bx, [W_TMP + 0]
        mov al, 60
        add bx, 60
        cmp bx, 128
        jbe .ok
        mov al, 128
        sub al, [W_TMP + 0]
.ok:    add ax, bp
        pop bx
        ret

make_program:                     ; a program + a keygroup a slice. CF = 1: failed
        pusha
        push es
        xor bp, bp
.kg:    push ds
        xor ax, ax
        mov ds, ax
        call 0x2345:0x1535
        pop ds
        jc .bad
        mov byte [es:0], 2
        mov ax, es
        mov bx, bp
        shl bx, 1
        mov [bx + W_KGSEG], ax
        inc bp
        cmp bp, [W_TMP + 0]
        jb .kg
        push ds
        xor ax, ax
        mov ds, ax
        call 0x2345:0x1535
        pop ds
        jc .bad
        push ds
        xor ax, ax
        mov ds, ax
        mov si, 0x1626            ; the OS's program template
        xor di, di
        mov cx, 192
        rep movsb
        pop ds
        mov di, SH_NAME           ; base[0..7] + CHOP
        mov si, W_NAMEBUF
        mov cx, 8
        rep movsb
        mov al, 13
        stosb
        mov al, 18
        stosb
        mov al, 25
        stosb
        mov al, 26
        stosb
        mov ax, [W_KGSEG]
        mov [es:1], ax
        mov ax, [W_TMP + 0]
        mov [es:0x2A], al
        call next_prog_number
        mov [es:0x0F], al
        xor bp, bp
.k2:    mov bx, bp
        shl bx, 1
        mov es, [bx + W_KGSEG]
        push ds
        xor ax, ax
        mov ds, ax
        mov si, 0x16E6            ; the OS's keygroup template
        xor di, di
        mov cx, 192
        rep movsb
        pop ds
        xor ax, ax
        mov cx, bp
        inc cx
        cmp cx, [W_TMP + 0]
        jae .last
        mov ax, [bx + W_KGSEG + 2]
.last:  mov [es:1], ax
        call slice_note
        mov [es:3], al
        mov [es:4], al
        mov si, [bx + W_SLSEG]    ; zone 1 = the slice (name; the OS links it on the rebuild)
        push ds
        mov ds, si
        mov si, SH_NAME
        mov di, 0x22
        mov cx, 12
        rep movsb
        pop ds
        mov ax, [bx + W_SLSEG]
        mov [es:0x38], ax
        mov byte [es:0x2E], 0
        mov byte [es:0x2F], 127
        inc bp
        cmp bp, [W_TMP + 0]
        jb .k2
        pop es
        popa
        clc
        ret
.bad:   pop es
        popa
        stc
        ret

next_prog_number:                 ; al = 1 + the highest program number (127 at most)
        push bx
        push cx
        push es
        push si
        xor ax, ax
        mov es, ax
        mov cl, [es:NUM_PROGS]
        xor ch, ch
        mov si, CATALOG
        xor bl, bl
        jcxz .d
.l:     push es
        mov es, [es:si]
        mov al, [es:0x0F]
        pop es
        cmp al, bl
        jb .n
        mov bl, al
.n:     add si, 2
        loop .l
.d:     mov al, bl
        inc al
        cmp al, 127
        jbe .x
        mov al, 127
.x:     pop si
        pop es
        pop cx
        pop bx
        ret

ch_mode:  db 0                    ; 0 EQUAL, 1 TRANS, 2 LAZY
ch_n:     db 8
ch_sens:  db 5
ch_cur:   db 0
ch_arm:   db 0
ch_lazy:  db 0                    ; 1 capturing, 2 captured
ch_busy:  db 0
ch_hseg:  dw 0
ch_msg:   dw 0
t_modes:  db "EQUALTRANSLAZY "
t_nosmp:  db "NO SAMPLE   "
t_slq:    db "    SLICES?  >GO"
t_lazy:   db "TAP F2  CUTS    "
t_busy:   db "WORKING...      "
t_noslice: db "NO SLICES FOUND "
t_nohdr:  db "TOO MANY ITEMS  "
t_nomem:  db "NOT ENOUGH MEM  "
t_made:   db "SLICES + PROGRAM"
t_fail:   db "CHOP FAILED     "
