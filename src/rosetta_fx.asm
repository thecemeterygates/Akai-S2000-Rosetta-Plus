; Rosetta FX (no EB16): the EFFECTS page + a preset engine on the L7A1045's own delay engine.
; Included by rosetta_menu.asm (same segment, DS = 0 at every entry point).
;
; Page 0x0C of mode 6 (stock "EB16 not present") becomes
;     >HALL    >WET 50          TYPE / WET (send level 0-99)
;     >T100 >F100 >R100         TIME % (delays/size) / FEEDBACK % / LFO RATE %
; '>' marks the selected field. Soft keys 0x40/0x41 (r2c1/r5c1) move it, the inner DATA wheel ([73A5]) and
; the +-1 step ([73AC]) and soft keys 0x44-0x47 change it. EFFECTS again = next type.

TICK      equ 0x73DA          ; ++ every 0.511 ms by int 9 (0FE4:0B92), measured on hw (not 2.04 ms)
KEYEV     equ 0x73D4          ; key event: 0x40 | n = soft key n pressed, 0xC0 | n = mode key, 0x60 = release
WHEEL     equ 0x73A5          ; data wheel delta (int 9 adds it; stock consumer 0FE4:04A6)
INCDEC    equ 0x73AC          ; +1 / -1 step from port 0x40 bits 5/2 with slow repeat (int 9; stock: value step, 0FE4:0468)
ROCKER    equ 0x73A4          ; the big knob's rocker ring (panel, added at 2345-side 1BD52 with the wheel): half push +-1,
                              ; full push +-5 = a jump. Stock: the cursor / a list 1 or 5 at a time (0FE4:0478, 1F50:05CE)
FXPAGE    equ 0x0C
NFIELDS   equ 5
F_TYPE    equ 0
F_WET     equ 1
F_TIME    equ 2
F_FB      equ 3
F_RATE    equ 4

; ---------------------------------------------------------------------------------------------
; EFFECTS key (0FE4:03CB, EB16-absent path; the OS draws page 0x0C from RAM right after).
; First press shows the FX page, pressing it again while there steps to the next type.
fx_entry:
        mov byte [MODE], MODE_FX
        pusha
        push es
        cmp byte [cs:ctx], CTX_MENU   ; the area menus share this page slot
        jne .fx
        xor al, al
        call pm_render
        jmp .done
.fx:    cmp byte [cs:ctx], CTX_SYN    ; ... and the SYNTH page
        jne .fx2
        xor al, al
        call fx_render
        jmp .done
.fx2:   cmp byte [cs:wasfx], 0
        je .show
        mov al, [cs:fxon]
        inc al
        call fxcnt
        cmp al, ah
        jb .s
        xor al, al
.s:     call fx_settype
.show:  mov byte [cs:onfx], 1
        xor al, al
        call fx_render
.done:  pop es
        popa
        retf

; soft key al (0-7) on the FX page (from key_hook in rosetta_home.asm)
fx_key: push ax
        mov ah, 1                 ; MFX with a REV type: the reverse's own menu (hi code)
        call hi_rv
        jc .lo
        add sp, 2
        jmp fx_tstep
.lo:    pop ax
        cmp al, 0
        je .left
        cmp al, 1
        je .right
        cmp al, 4
        je .dec
        cmp al, 6
        je .dec
        cmp al, 5
        je .inc
        cmp al, 7
        je .inc
        ret
.left:  mov al, [cs:fcur]
        dec al
        jns .l2
        mov al, NFIELDS - 1
.l2:    mov [cs:fcur], al
        jmp fx_show
.right: mov al, [cs:fcur]
        inc al
        cmp al, NFIELDS
        jb .r2
        xor al, al
.r2:    mov [cs:fcur], al
        jmp fx_show
.dec:   mov ax, -1
        jmp fx_change
.inc:   mov ax, 1
        jmp fx_change

; wheel / inc-dec on the FX page: called from lfo_hook (main-loop wait), grabs the deltas atomically
fx_poll:
        cmp byte [cs:mfx], 0
        jne .ok
        cmp byte [MODE], MODE_FX
        jne .r
        cmp byte [PAGE], FXPAGE
        jne .r
.ok:    xor al, al
        xchg al, [ROCKER]     ; (taken on our pages: the stock page underneath must not move its cursor)
        or al, al
        jnz .rk
        xchg al, [WHEEL]
        or al, al
        jnz .go
        xchg al, [INCDEC]     ; +1 / -1 (stock treats it as a value step on the field, like the wheel)
        or al, al
        jz .r
.go:    pusha                 ; DATA wheel / step: change the value
        push es
        cmp byte [cs:mfx], 0
        jne .v
        cmp byte [cs:ctx], CTX_MENU
        jne .v
        call pm_move          ; menu: move the selection
        jmp .gd
.v:     push ax
        mov ah, 2
        call hi_rv
        jc .v2
        add sp, 2
        call fx_tstep
        jmp .gd
.v2:    pop ax
        cbw
        call fx_change
.gd:
        pop es
        popa
.r:     ret
; rocker al: half push = the next / previous knob, full push = a jump (REV menu: a page; area menus: 5 entries,
; as stock lists)
.rk:    pusha
        push es
        cmp byte [cs:mfx], 0
        jne .k0
        cmp byte [cs:ctx], CTX_MENU
        jne .k0
        call pm_move          ; area menu: +-1 / +-5 entries
        jmp .gd
.k0:    mov dl, 9             ; the REV menu's keys: 9 / 8 next / previous knob over the pages, 5 / 4 PAGE
        or al, al
        jns .k1
        mov dl, 8
        neg al
.k1:    cmp al, 5
        jb .k2
        sub dl, 4
.k2:    mov al, dl
        push ax
        mov ah, 1
        call hi_rv
        jc .k3
        add sp, 2
        call fx_tstep
        jmp .gd
.k3:    pop ax                ; the FX page: the cursor
        test al, 1
        jz .k4
        call fx_key.right
        jmp .gd
.k4:    call fx_key.left
        jmp .gd

; ax = signed delta for the selected field
fx_change:
        mov bl, [cs:fcur]
        cmp bl, F_TYPE
        jne .p
        call fxcnt            ; ah = number of presets
        mov cl, [cs:fxon]
        add al, cl            ; wrap into 0..n-1
.w1:    or al, al
        jns .w2
        add al, ah
        jmp .w1
.w2:    cmp al, ah
        jb .w3
        sub al, ah
        jmp .w2
.w3:    cmp al, cl
        je fx_show
        call fx_settype
        jmp fx_show
.p:     xor bh, bh
        shl bx, 1
        mov di, [cs:fparam+bx]
        cmp bl, F_WET * 2
        jne .nw
        cmp byte [cs:mfx], 0
        je .nw
        mov di, iwet          ; MFX: the input's send instead of WET
.nw:    mov cx, [cs:fmin+bx]
        mov dx, [cs:fmax+bx]
        cmp bl, F_FB * 2
        jne .lim
        push ax
        push bx
        call fbmax
        mov dx, ax
        pop bx
        pop ax
.lim:   add ax, [cs:di]
        cmp ax, cx
        jge .c1
        mov ax, cx
.c1:    cmp ax, dx
        jle .c2
        mov ax, dx
.c2:    cmp ax, [cs:di]
        je fx_show
        mov [cs:di], ax
        cmp bl, F_WET * 2
        jne .ap
        call setsend
        jmp fx_show
.ap:    mov byte [cs:keepph], 1
        call fx_apply
        mov byte [cs:keepph], 0
        ; fall through
fx_show:
        mov al, 1
        jmp fx_render

; al = type: select it with default TIME / FB / RATE (WET stays)
fx_settype:
        mov [cs:fxon], al
        mov word [cs:ptime], 100
        mov word [cs:prate], 100
        call fbmax
        cmp ax, 99
        jbe .f
        mov ax, 99            ; (0.28: 99: LOOPER's FB 100 = FREEZE)
.f:     mov [cs:pfb], ax
        mov byte [cs:keepph], 0
        call setsend
        jmp fx_apply

; send level byte = WET * 255 / 99 into reg7 word1 (dest 0xF = delay engine) via fxsendv; the same for the
; input (MFX IN) into isendv, 0 when IN is 0 (the stock monitor voices' word1)
setsend:
        mov ax, [cs:pwet]
        call sendlvl
        mov [cs:fxsendv], ax
        mov ax, [cs:iwet]
        or ax, ax
        jz .i
        call sendlvl
.i:     mov [cs:isendv], ax
        ret
sendlvl:
        mov dx, 255
        mul dx
        mov bx, 99
        div bx
        mov ah, al
        mov al, 0x0F
        ret

; ---------------------------------------------------------------------------------------------
; MFX: EFFECTS on the sampling screen (mode 4) shows the FX page over the meter page (the input only runs in
; mode 4, so this stays there): same TYPE / TIME / FB / RATE (one delay engine), WET becomes IN = how much
; of the input goes into it (the hi code puts isendv on the OS's input monitor voices 15h / 17h).
; EFFECTS again = next type, home = back to the meter (key_hook), any mode change closes it (page0_hook).
mfx_key:
        cmp byte [cs:mfx], 0
        je .show
        mov al, [cs:fxon]
        inc al
        call fxcnt
        cmp al, ah
        jb .s
        xor al, al
.s:     call fx_settype
        jmp fx_show
.show:  mov byte [cs:mfx], 1
        mov byte [PAGE], REC_ARM  ; the meter page has no fields for the wheel to change underneath
        jmp fx_show

; 0FE4:3827, the REC meter's draw (far call 2345:0B0B): skipped while the MFX page covers it
meter_gate:
        cmp byte [cs:mfx], 0
        jne .r
        jmp 0x2345:0x0B0B
.r:     retf

; MFX with a REV type: the live reverse's menu is in the hi code (src/rosetta_rvui.asm, header +1B): ah = 0 draw
; (al != 0: LCD too), 1 = soft key al, 2 = value step al. CF = 1: not ours (not MFX, no hi code, not a REV type);
; else al = a TYPE step for us (0 = none)
hi_rv:  cmp byte [cs:ctx], CTX_SYN    ; the SYNTH page: header +1E, same protocol (+ ah = 3: home key)
        je .h
        cmp byte [cs:mfx], 0
        je .no
.h:     push es
        push bx
        mov bx, LOAD_SEG
        mov es, bx
        cmp byte [es:3], 1        ; the hi code is in and running (src/rosetta_load.asm state)
        pop bx
        pop es
        jne .no
        cmp byte [cs:ctx], CTX_SYN
        je .syn
        call HI_SEG:0x001B
        ret
.syn:   call HI_SEG:0x001E
        ret
.no:    stc
        ret

; al = signed TYPE step from the REV menu (0 = none)
fx_tstep:
        or al, al
        jz .r
        call fxcnt                ; ah = number of presets
        add al, [cs:fxon]
.w1:    or al, al
        jns .w2
        add al, ah
        jmp .w1
.w2:    cmp al, ah
        jb .w3
        sub al, ah
        jmp .w2
.w3:    call fx_settype
        jmp fx_show
.r:     ret

presetptr:                    ; si = record of preset [cs:fxon]
        mov bl, [cs:fxon]
        xor bh, bh
        shl bx, 1
        mov si, [cs:fxhdr]
        mov si, [cs:si]
        mov si, [cs:si+bx]
        ret

fxcnt:  push bx               ; ah = number of FX presets
        mov bx, [cs:fxhdr]
        mov ah, [cs:bx + 6]
        pop bx
        ret

fbmax:  push si               ; ax = the preset's FEEDBACK limit (0 = no feedback taps)
        push bx
        call presetptr
        mov al, [cs:si+8]
        xor ah, ah
        pop bx
        pop si
        ret

; ---------------------------------------------------------------------------------------------
; 2 x 16 text into fxbuf -> page 0x0C RAM text (2D95:1402 / 1415); al != 0: also straight to the LCD
fx_render:
        cmp byte [cs:ctx], CTX_SYN    ; SYNTH: the hi code fills fxbuf
        jne .nsy
        push ax
        mov ah, 0
        call hi_rv
        pop ax
        jmp fx_out
.nsy:   push ax
        mov ah, 0
        call hi_rv
        pop ax
        jnc .r0
        push ax
        mov ah, F_TYPE
        call mark
        mov [cs:fxbuf], al
        call presetptr
        mov cx, 8
        mov di, fxbuf + 1
.n:     mov al, [cs:si]
        mov [cs:di], al
        inc si
        inc di
        loop .n
        mov ah, F_WET
        call mark
        mov [cs:fxbuf + 9], al
        mov word [cs:fxbuf + 10], 'WE'
        mov byte [cs:fxbuf + 12], 'T'
        mov ax, [cs:pwet]
        cmp byte [cs:mfx], 0
        je .w
        mov word [cs:fxbuf + 10], 'IN'
        mov byte [cs:fxbuf + 12], ' '
        mov ax, [cs:iwet]
.w:     mov di, fxbuf + 13
        call itoa3
        mov ah, F_TIME
        call mark
        mov [cs:fxbuf + 16], al
        mov byte [cs:fxbuf + 17], 'T'
        mov ax, [cs:ptime]
        mov di, fxbuf + 18
        call itoa3
        mov ah, F_FB
        call mark
        mov [cs:fxbuf + 21], al
        mov byte [cs:fxbuf + 22], 'F'
        mov ax, [cs:pfb]
        mov di, fxbuf + 23
        call itoa3
        mov ah, F_RATE
        call mark
        mov [cs:fxbuf + 26], al
        mov byte [cs:fxbuf + 27], 'R'
        mov ax, [cs:prate]
        mov di, fxbuf + 28
        call itoa3
        mov byte [cs:fxbuf + 31], ' '
        pop ax
        jmp fx_out
.r0:    ret
; the hi code's SYNTH page, far: fxbuf (filled by it) -> the page
syn_out:
        push es
        pusha
        mov al, 1
        call fx_out
        popa
        pop es
        retf

; fxbuf -> page 0x0C RAM text (2D95:1402 / 1415); al != 0: also straight to the LCD
fx_out: push ax
        mov ax, DATA_SEG
        mov es, ax
        mov si, fxbuf
        mov di, FXPAGE_L1
        call cpy16
        mov di, FXPAGE_L2
        call cpy16
        pop ax
        or al, al
        jz .r
        mov al, 0x80          ; HD44780: line 1, 16 chars, line 2, 16 chars, cursor off
        call lcd_cmd
        mov si, fxbuf
        call lcd16
        mov al, 0xC0
        call lcd_cmd
        call lcd16
        mov al, 0x0C
        call lcd_cmd
.r:     ret

mark:   mov al, ' '           ; ah = field -> al = '>' if selected
        cmp ah, [cs:fcur]
        jne .m
        mov al, '>'
.m:     ret

itoa3:  push ax               ; ax = 0..999 -> 3 chars right-aligned at cs:di
        push bx
        push dx
        push ax
        mov bx, 10
        xor dx, dx
        div bx
        add dl, '0'
        mov [cs:di + 2], dl
        xor dx, dx
        div bx
        add dl, '0'
        mov [cs:di + 1], dl
        add al, '0'
        mov [cs:di], al
        pop ax
        cmp ax, 100
        jae .d
        mov byte [cs:di], ' '
        cmp ax, 10
        jae .d
        mov byte [cs:di + 1], ' '
.d:     pop dx
        pop bx
        pop ax
        ret

cpy16:  mov cx, 16
.c:     mov al, [cs:si]
        stosb
        inc si
        loop .c
        ret

lcd_wait:                     ; busy flag at 0x62 bit 7 (as 0FE4:07FA), with a timeout
        push ax
        push cx
        mov cx, 4000
.w:     in al, 0x62
        test al, 0x80
        loopnz .w
        pop cx
        pop ax
        ret
lcd_cmd: call lcd_wait
        out 0x62, al
        ret
lcd16:  mov cx, 16            ; cs:si -> LCD data, si advanced
.l:     call lcd_wait
        mov al, [cs:si]
        out 0x60, al
        inc si
        loop .l
        ret

; ---------------------------------------------------------------------------------------------
; FX engine. Reg A function fn = one tap of the 65536-sample delay line (measured, see README):
;   select 0x80 = 0x0A00 | fn; 0x82 = Q15 gain, low 2 bits route (1 L, 0 R, 3 feedback); 0x84 = 2 - delay
; (2345:81B4/81E4 do the same from the int8 table at DS:6D00). Main-loop context only: nothing in the
; ISRs touches 0x80-0x8C (s2k_ui.py isrcheck), so a select + data pair can't be split.
M_FNE     equ 0               ; LFO slot record (scaled copy of the preset's, phase runs in place)
M_FNO     equ 1
M_ROUTE   equ 2
M_GAIN    equ 3
M_CENTER  equ 5
M_DEPTH   equ 7
M_INC     equ 9
M_PHASE   equ 11
M_SAW     equ 13              ; 0.28: 80h = a pitch-shift slot (sawtooth delay, sin^2 window on the gain)
M_EG      equ 14              ; the gain this pass (x the window on a saw slot)
MDEF      equ 13
MSLOT     equ 16
P_NAME    equ 0               ; preset record: name[8], fbmax, nstatic, nmod, taps (5 B), slots (MDEF B)
P_FBMAX   equ 8
P_NST     equ 9
P_NMOD    equ 10
P_TAPS    equ 11

; al = fn, bx = gain word, cx = delay (samples, >= 2); keeps all registers
wtap:   push ax
        push dx
        mov ah, 0x0A
        mov dx, ax
        out 0x80, ax
        mov ax, bx
        out 0x82, ax
        mov ax, dx
        out 0x80, ax
        mov ax, 2
        sub ax, cx
        out 0x84, ax
        pop dx
        pop ax
        ret

; al = fn, cx = delay (samples, >= 2): the tap's length only; keeps all registers
wlen:   push ax
        mov ah, 0x0A
        out 0x80, ax
        mov ax, 2
        sub ax, cx
        out 0x84, ax
        pop ax
        ret

; ax (unsigned) * bx % -> ax, saturating at 0xFFFF
scaleu: mul bx
        cmp dx, 100
        jae .max
        div word [cs:c100]
        ret
.max:   mov ax, 0xFFFF
        ret

; ax (signed) * bx % -> ax, saturating at +-32767 (keeps idiv from faulting)
scales: imul bx
        cmp dx, 0x31
        jg .pmax
        cmp dx, -0x32
        jl .nmax
        idiv word [cs:c100]
        ret
.pmax:  mov ax, 32767
        ret
.nmax:  mov ax, -32767
        ret

; program preset [cs:fxon] with TIME / FB / RATE: all 30 taps silent, static taps, then LFO slots
; (keepph = 1 keeps the running LFO phases, for parameter edits)
fx_apply:
        pusha
        mov byte [cs:nmods], 0
        mov al, 1
        xor bx, bx
        mov cx, 2
.z:     cmp al, 11
        je .zn
        call wtap
.zn:    inc al
        cmp al, 32
        jb .z
        call presetptr
        mov dl, [cs:si + P_NST]
        mov dh, [cs:si + P_NMOD]
        add si, P_TAPS
.st:    or dl, dl
        jz .md
        push dx
        mov ax, [cs:si + 3]   ; delay * TIME
        mov bx, [cs:ptime]
        call scaleu
        cmp ax, 2
        jae .d2
        mov ax, 2
.d2:    mov cx, ax
        mov ax, [cs:si + 1]   ; gain word; feedback taps * FB
        mov bx, ax
        and bl, 3
        cmp bl, 3
        jne .g
        and al, 0xFC
        mov bx, [cs:pfb]
        call scales
        and al, 0xFC
        or al, 3
.g:     mov bx, ax
        mov al, [cs:si]
        call wtap
        pop dx
        add si, 5
        dec dl
        jmp .st
.md:    push dx               ; (scaleu / scales clobber dx: keep the slot count)
        mov di, mslots
        mov cl, dh
.cp:    or cl, cl
        jz .cpd
        push cx
        mov ax, [cs:si]       ; fnE, fnO
        mov [cs:di + M_FNE], ax
        mov al, [cs:si + 2]   ; route (bit 7: a saw slot)
        mov ah, al
        and ax, 0x8003
        mov [cs:di + M_ROUTE], al
        mov [cs:di + M_SAW], ah
        mov ax, [cs:si + 3]   ; gain (* FB on feedback slots)
        cmp byte [cs:di + M_ROUTE], 3
        jne .mg
        mov bx, [cs:pfb]
        call scales
.mg:    mov [cs:di + M_GAIN], ax
        mov ax, [cs:si + 5]   ; center, depth * TIME
        mov bx, [cs:ptime]
        call scaleu
        mov [cs:di + M_CENTER], ax
        mov ax, [cs:si + 7]   ; (signed: a saw's depth < 0 = sharp)
        mov bx, [cs:ptime]
        call scales
        mov [cs:di + M_DEPTH], ax
        mov ax, [cs:si + 9]   ; phase increment * RATE
        mov bx, [cs:prate]
        call scaleu
        mov [cs:di + M_INC], ax
        cmp byte [cs:keepph], 0
        jne .kp
        mov ax, [cs:si + 11]
        mov [cs:di + M_PHASE], ax
.kp:    pop cx
        add si, MDEF
        add di, MSLOT
        dec cl
        jmp .cp
.cpd:   pop dx
        mov al, [TICK]
        mov [cs:lasttick], al
        mov [cs:nmods], dh
        xor cl, cl
        call lfo_run
        popa
        ret

; main-loop wait (0FE4:000A..001B spins on the tick until 10 have passed): FX page wheel, then the LFO
; slots once per tick. Returns AL = tick like the 2345:0A47 it replaces.
lfo_hook:
        call 0x2345:0x0A47
        push ax
        call fx_poll
        call pm_poll
        call rec_poll
        call LOAD_SEG:0x0000  ; hi code: loads it on the first tick, then runs its tick (src/rosetta_load.asm)
        pop ax
        push ax
        cmp byte [cs:nmods], 0
        je .out
        mov ah, al
        sub ah, [cs:lasttick]
        jz .out
        mov [cs:lasttick], al
        pusha
        mov cl, ah
        call lfo_run
        popa
.out:   pop ax
        retf

; cl = elapsed ticks. Per slot: phase += inc * cl; delay = center + depth * sin(phase) (8.8 fixed);
; integer n and fraction f -> the even-delay tap and the odd-delay tap get g*(1-f) / g*f, so a tap
; only moves (by 2) while its gain is ~0: fractional delay without clicks.
lfo_run:
        mov si, mslots
        mov ch, [cs:nmods]
.sl:    or ch, ch
        jz .done
        push cx
        mov al, cl
        xor ah, ah
        mul word [cs:si + M_INC]
        add [cs:si + M_PHASE], ax
        mov bl, [cs:si + M_PHASE + 1]
        xor bh, bh
        shl bx, 1
        mov di, [cs:fxhdr]
        mov di, [cs:di + 4]         ; sintab (in the FX bank)
        mov ax, [cs:si + M_GAIN]
        cmp byte [cs:si + M_SAW], 0
        jne .saw
        mov [cs:si + M_EG], ax
        mov ax, [cs:di + bx]
        jmp .sv
.saw:   add bx, 128                 ; saw slot: gain x sin^2(pi phase) = (1 - cos(2 pi phase)) / 2
        and bx, 511
        mov ax, 16384
        sub ax, [cs:di + bx]
        shr ax, 1
        imul word [cs:si + M_GAIN]
        shl ax, 1
        rcl dx, 1
        shl ax, 1
        rcl dx, 1
        mov [cs:si + M_EG], dx
        mov ax, [cs:si + M_PHASE]   ; delay ramp: (phase - 8000h) / 2 = Q14 -1 .. +1
        xor ah, 0x80
        sar ax, 1
.sv:    imul word [cs:si + M_DEPTH] ; dx:ax = sin (Q14) * depth (samples)
        mov bx, ax
        shr bx, 6
        and bx, 0xFF                ; f = 1/256 sample
        shl dx, 2
        shr ax, 14
        or dx, ax
        add dx, [cs:si + M_CENTER]  ; n
        push dx
        mov ax, 256
        sub ax, bx
        imul word [cs:si + M_EG]
        mov al, ah
        mov ah, dl
        and al, 0xFC
        or al, [cs:si + M_ROUTE]
        mov di, ax                  ; gain word at delay n
        mov ax, bx
        imul word [cs:si + M_EG]
        mov al, ah
        mov ah, dl
        and al, 0xFC
        or al, [cs:si + M_ROUTE]
        mov bp, ax                  ; gain word at delay n + 1
        pop cx                      ; n
        mov al, [cs:si + M_FNE]
        mov ah, [cs:si + M_FNO]
        test cl, 1
        jz .even
        xchg al, ah                 ; n odd: the odd tap takes delay n
.even:  mov dx, ax                  ; dl = the tap at delay n, dh = the tap at n + 1
        ; lengths first (a tap only moves while its gain is ~0), then the two gains back to back with
        ; interrupts off: between the two gain writes the pair's sum is off by this pass's step, and a sample
        ; the chip takes there is a blip (hw 0.27: ~40 clicks/s on held chords with every LFO type when the
        ; pair was written gain, length, gain, length)
        mov al, dl
        call wlen
        mov al, dh
        inc cx
        call wlen
        pushf
        cli
        mov al, dl
        mov ah, 0x0A
        out 0x80, ax
        mov ax, di
        out 0x82, ax
        mov al, dh
        mov ah, 0x0A
        out 0x80, ax
        mov ax, bp
        out 0x82, ax
        popf
        pop cx
        add si, MSLOT
        dec ch
        jmp .sl
.done:  ret

; ---------------------------------------------------------------------------------------------
fcur:     db 0                ; selected field
onfx:     db 0                ; FX page is showing (cleared by page0_hook on any mode entry)
wasfx:    db 0                ; ... and was showing when this mode entry started
keepph:   db 0
nmods:    db 0
lasttick: db 0
pwet:     dw 50
iwet:     dw 0                ; MFX IN (0-99): input into the FX, 0 = stock
isendv:   dw 0                ; its reg7 word1 for the input monitor voices (hi code reads it)
mfx:      db 0                ; MFX page showing over the REC meter
ptime:    dw 100
pfb:      dw 0                 ; boot preset OFF has no feedback (fbmax 0)
prate:    dw 100
c100:     dw 100
fparam:   dw 0, pwet, ptime, pfb, prate
fmin:     dw 0, 0, 25, 0, 10
fmax:     dw 0, 99, 200, 0, 400           ; FB max is per preset (fbmax)
fxbuf:    times 32 db ' '
mslots:   times 4 * MSLOT db 0

; FX bank: in the hi code (tools/fxbank.py -> build/hi_fx.inc), which sets fxhdr to it when it loads
; (MENU_SEG offsets past 0x1600 are hi RAM). Without it: OFF only.
fxhdr:    dw fx_fb
fx_fb:    dw fb_ptrs, fb_short, fb_short  ; preset_ptrs, fx_short, sintab
          db 1
fb_ptrs:  dw fb_off
fb_off:   db 'OFF     ', 0, 0, 0
fb_short: db ' OFF '
