; SYNTH page (0.26): MULTI opens it (the user: "MULTI = SYNTH only"). Included by rosetta_hi.asm.
; The menu code (src/rosetta_fx.asm hi_rv, ctx = CTX_SYN) forwards to header +1E, DS = 0:
;   ah = 0 fill the menu code's fxbuf (it shows it), 1 = soft key al, 2 = value step al, 3 = home key
;   (al = 1: went back a level, 0: let the menu code go HOME). Keys / steps draw through MENU_SEG:0027.
; Top: a mode menu with arrows (ANALOG, FAKE FM, WAVETABLE), F2 = GO. ANALOG = 4 pages x 4 knobs on the current
; program (every program with the selected number, every keygroup): wave (ROSETTA ROM programs), filter, envelopes,
; the SYNTH layer's drift / detune / LFO. Keys as the REV menu: F1 / F2 knob, wheel / GROUP value, PAGE page,
; rocker = knob (half) / page (full), home = back to the mode menu, then HOME.
SY_NM     equ 4                   ; modes
KG_CUT    equ 7                   ; keygroup bytes in RAM (S1000 layout first; mapped in the emulator by nudging the
KG_KEY    equ 8                   ; stock EDIT pages and diffing, 2026-10-15)
KG_E2F    equ 11                  ; (S1000 ENV2>FILTER: the S2000 ignores it, see KG_FM3)
KG_A1     equ 12                  ; ENV1 A D S R
KG_D1     equ 13
KG_S1     equ 14
KG_R1     equ 15
KG_E2R1   equ 20                  ; ENV2 rates / levels (4-stage): R1 20, R2 9Dh, R3 21, R4 23,
KG_E2R3   equ 21                  ;                                L1 9Ch, L2 9Eh, L3 22, L4 9Fh
KG_E2L3   equ 22
KG_E2R4   equ 23
KG_E2L1   equ 0x9C
KG_E2L2   equ 0x9E
KG_RES    equ 0x95                ; FILTER Reso
KG_FM3    equ 0x99                ; FILTER MOD 3 amount (1 / 2 at 97h / 98h)
HD_FM3S   equ 0x56                ; program header: FILTER MOD 3 source (10 = Env2; 0 = none, as an S1000 load leaves it)
SRC_ENV2  equ 10
S_NONE    equ 0
S_WAV     equ 1                   ; ROSETTA ROM wave of every "RS ..." zone
S_KG      equ 2                   ; keygroup byte (arg = offset), unsigned
S_KGS     equ 3                   ; ... signed
S_PAR     equ 4                   ; SYNTH layer CC value (arg = par index), 0-127
S_FEN     equ 5                   ; filter env amount: MOD 3 amount + its source = Env2 + ENV2 peak levels
PROG_N    equ 0x74F4              ; programs in memory
PROG_SEL  equ 0x758A              ; the selected program number
FTAB      equ 0xB0D0              ; program segments, then sample segments
HD_KGN    equ 0x2A                ; program header: keygroups
HD_KG1    equ 0x01                ; ... first keygroup's segment (each keygroup's +1 = the next one)
ZN_AT     equ 0x22                ; keygroup: zone 1 (24 B each: name[12] .. +22 = its sample's segment)

syn_ui:
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push es
        cmp ah, 1
        je .key
        cmp ah, 2
        je .step
        cmp ah, 3
        je .home
        call sy_draw              ; ah = 0: fill fxbuf, the menu code shows it
        xor al, al
        jmp .ok
.key:   call sy_key
        jmp .shw
.step:  call sy_step
        jmp .shw
.home:  xor al, al
        cmp byte [cs:sy_lvl], 0
        je .ok
        mov byte [cs:sy_lvl], 0   ; pages -> the mode menu
        mov al, 1
        push ax
        call sy_draw
        call 0x3EA0:0x0027
        pop ax
        jmp .ok
.shw:   call sy_draw
        call 0x3EA0:0x0027        ; fxbuf -> page RAM + LCD
        xor al, al
.ok:    clc
        pop es
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        retf

; soft key al: 0 F1, 1 F2, 4 / 5 PAGE, 6 / 7 GROUP (value), 8 / 9 rocker knob
sy_key: cmp byte [cs:sy_lvl], 0
        jne .pg
        cmp al, 1                 ; mode menu: F2 = GO, the rest step the mode
        je .go
        mov dl, 1
        cmp al, 5
        je .mv
        cmp al, 7
        je .mv
        cmp al, 9
        je .mv
        mov dl, -1
        cmp al, 4
        je .mv
        cmp al, 6
        je .mv
        cmp al, 8
        je .mv
        ret
.mv:    mov al, dl
        jmp sy_mstep
.go:    mov byte [cs:sy_lvl], 1
        mov byte [cs:sy_page], 0
        mov byte [cs:sy_cur], 0
        ret
.pg:    cmp byte [cs:sy_mode], 1  ; CHOP: its own keys
        jne .pg0
        jmp ch_key
.pg0:   cmp byte [cs:sy_mode], 0  ; FAKE FM / WAVETABLE: nothing yet
        jne .r
        cmp al, 0
        je .left
        cmp al, 1
        je .right
        cmp al, 8
        je .left
        cmp al, 9
        je .right
        cmp al, 4
        je .pdn
        cmp al, 5
        je .pup
        cmp al, 6
        je .dn
        cmp al, 7
        je .up
.r:     ret
.dn:    mov al, -1
        jmp sy_step
.up:    mov al, 1
        jmp sy_step
.pdn:   mov al, [cs:sy_page]
        dec al
        jns .p
        mov al, SY_NP - 1
        jmp .p
.pup:   mov al, [cs:sy_page]
        inc al
        cmp al, SY_NP
        jb .p
        xor al, al
.p:     mov [cs:sy_page], al
        ret
.left:  mov al, [cs:sy_cur]       ; knobs straight over the pages
        dec al
        jns .c
        mov al, 3
        call .pdn
        mov al, 3
        jmp .c
.right: mov al, [cs:sy_cur]
        inc al
        cmp al, 4
        jb .c
        call .pup
        xor al, al
.c:     mov [cs:sy_cur], al
        ret

; mode menu step al
sy_mstep:
        add al, [cs:sy_mode]
        jns .a
        mov al, SY_NM - 1
.a:     cmp al, SY_NM
        jb .b
        xor al, al
.b:     mov [cs:sy_mode], al
        ret

; value step al on the knob under the cursor (mode menu: the mode)
sy_step:
        cmp byte [cs:sy_lvl], 0
        je sy_mstep
        cmp byte [cs:sy_mode], 1
        jne .s0
        jmp ch_step
.s0:    cmp byte [cs:sy_mode], 0
        jne .r
        mov dl, al
        call sy_fld
        mov bl, [cs:si + 1]
        cmp bl, S_NONE
        je .r
        call sy_get
        cmp ax, 0xFF              ; (no program / not an RS wave)
        je .r
        mov cl, dl
        xor ch, ch
        or cl, cl
        jns .a
        mov ch, 0xFF
.a:     add ax, cx
        push ax                   ; clamp: min (signed for S_KGS), max
        mov al, [cs:si + 4]
        xor ah, ah
        cmp bl, S_KGS
        je .m00
        cmp bl, S_FEN
        jne .m0
.m00:   cbw
.m0:    mov cx, ax
        pop ax
        cmp ax, cx
        jge .m1
        mov ax, cx
.m1:    mov cl, [cs:si + 5]
        xor ch, ch
        cmp ax, cx
        jle .m2
        mov ax, cx
.m2:    jmp sy_set
.r:     ret

; si = the field under the cursor
sy_fld: mov al, [cs:sy_page]
        shl al, 1
        shl al, 1
        add al, [cs:sy_cur]
        mov ah, RVF
        mul ah
        add ax, sy_fields
        mov si, ax
        ret

; es = the first program with the selected number (ZF = 0), ZF = 1: none
sy_prog1:
        xor cx, cx
; es = the next program after index cx with the selected number; cx = its index + 1. ZF = 1: no more
sy_progn:
        mov al, [PROG_N]
        xor ah, ah
.l:     cmp cx, ax
        jae .none
        mov bx, cx
        shl bx, 1
        mov bx, [FTAB + bx]
        inc cx
        mov es, bx
        mov bl, [es:0x0F]
        cmp bl, [PROG_SEL]
        jne .l
        or cx, cx                 ; ZF = 0
        ret
.none:  xor bx, bx                ; ZF = 1
        ret

; ax = the value of field si (kind bl) from the first keygroup of the current program; FFh = none. Keeps bx.
sy_get: push bx
        call sy_get0
        pop bx
        ret
sy_get0:
        cmp bl, S_PAR
        jne .k
        mov bl, [cs:si + 2]
        xor bh, bh
        mov al, [cs:par + bx]
        xor ah, ah
        ret
.k:     push es
        call sy_prog1
        jz .none
        mov es, [es:HD_KG1]
        mov bx, [cs:si + 2]
        cmp byte [cs:si + 1], S_WAV
        je .w
        mov al, [es:bx]
        xor ah, ah
        cmp byte [cs:si + 1], S_KGS
        je .s
        cmp byte [cs:si + 1], S_FEN
        jne .r
.s:     cbw
.r:     pop es
        ret
.w:     push di                   ; (di = the draw pointer)
        call sy_zwave             ; zone 1's wave
        pop di
        jmp .r
.none:  mov ax, 0xFF
        pop es
        ret

; al = the ROSETTA ROM wave index of the zone at es:ZN_AT + di (FFh: not an RS wave)
sy_zwave:
        xor di, di
sy_zw:  push si
        push dx
        cmp word [es:ZN_AT + di], 0x1D1C ; "RS"
        jne .no
        cmp byte [es:ZN_AT + di + 2], 0x0A
        jne .no
        mov si, sy_waves
        xor ax, ax
.l:     mov dx, [cs:si]
        cmp [es:ZN_AT + di + 3], dx
        jne .n
        mov dl, [cs:si + 2]
        cmp [es:ZN_AT + di + 5], dl
        je .r
.n:     add si, 3
        inc ax
        cmp ax, 5
        jb .l
.no:    mov ax, 0xFF
.r:     pop dx
        pop si
        ret

; field si (kind bl) = ax, on every keygroup of every program with the selected number
sy_set: cmp bl, S_PAR
        jne .k
        mov bl, [cs:si + 2]
        xor bh, bh
        mov [cs:par + bx], al
        ret
.k:     mov [cs:sy_val], al
        push es
        xor cx, cx
.p:     push si
        call sy_progn
        pop si
        jz .done
        push cx
        cmp byte [cs:si + 1], S_FEN
        jne .h
        mov byte [es:HD_FM3S], SRC_ENV2
.h:     mov cl, [es:HD_KGN]
        xor ch, ch
        jcxz .nk
        mov dx, [es:HD_KG1]
.kg:    mov es, dx
        mov al, [cs:sy_val]
        cmp byte [cs:si + 1], S_WAV
        je .w
        mov bx, [cs:si + 2]
        mov [es:bx], al
        cmp byte [cs:si + 1], S_FEN
        jne .nx
        call sy_peak
        jmp .nx
.w:     call sy_setwave
.nx:    mov dx, [es:1]
        loop .kg
.nk:    pop cx
        jmp .p
.done:  pop es
        ret

; this keygroup (es): every RS zone onto wave al: its name and its sample's segment
sy_setwave:
        push si
        push cx
        push dx
        mov bl, 3
        mul bl
        add ax, sy_waves
        mov bp, ax                ; bp = the wave's 3 name chars
        xor di, di
.z:     push di
        call sy_zw
        pop di
        cmp ax, 0xFF
        je .nz
        mov ax, [cs:bp]           ; rename: "RS " + wave + " n"
        mov [es:ZN_AT + di + 3], ax
        mov al, [cs:bp + 2]
        mov [es:ZN_AT + di + 5], al
        call sy_findsmp           ; ax = the sample's segment (0: not loaded)
        or ax, ax
        jz .nz
        mov [es:ZN_AT + di + 22], ax
.nz:    add di, 24
        cmp di, 4 * 24
        jb .z
        pop dx
        pop cx
        pop si
        ret

; ax = the segment of the sample named like the zone es:ZN_AT + di (searched after the programs), 0 = none
sy_findsmp:
        push bx
        push cx
        push si
        push ds
        mov cl, [PROG_N]
        xor ch, ch
        mov si, cx
        shl si, 1
        add si, FTAB
        mov cx, 200               ; (the samples follow the programs; 0 ends the table)
.l:     mov ax, [si]
        or ax, ax
        jz .none
        push es
        push di
        push si
        mov ds, ax
        mov si, 3                 ; sample header: name at +3
        add di, ZN_AT
        push cx
        mov cx, 12
        repe cmpsb
        pop cx
        pop si
        pop di
        pop es
        push word 0               ; ds = 0 again (flags kept)
        pop ds
        je .hit
        add si, 2
        loop .l
.none:  xor ax, ax
.hit:   pop ds
        pop si
        pop cx
        pop bx
        ret

; keygroup es: ENV2 rises to a peak (an S1000 load leaves L1 = L2 = 0: a flat filter envelope)
sy_peak:
        cmp byte [es:KG_E2L1], 0
        jne .r
        cmp byte [es:KG_E2L2], 0
        jne .r
        mov byte [es:KG_E2L1], 99
        mov byte [es:KG_E2L2], 99
.r:     ret

; every tick: when the program count changes (boot autoload, LOAD), route the ROSETTA ROM programs' filter env
; (their S1000 ENV2>FILTER) as the S2000 wants it: MOD 3 source Env2, its amount, ENV2 peak levels
sy_fixrs:
        mov al, [PROG_N]
        cmp al, [cs:sy_pn]
        je .r
        mov [cs:sy_pn], al
        pusha
        push es
        xor cx, cx
        xor ah, ah
.p:     cmp cl, [PROG_N]
        jae .d
        mov bx, cx
        shl bx, 1
        mov es, [FTAB + bx]
        inc cx
        cmp word [es:3], 0x1D1C   ; "RS " programs
        jne .p
        cmp byte [es:5], 0x0A
        jne .p
        cmp byte [es:HD_FM3S], 0  ; (only as loaded: no source yet)
        jne .p
        mov byte [es:HD_FM3S], SRC_ENV2
        push cx
        push es
        mov cl, [es:HD_KGN]
        xor ch, ch
        jcxz .nk
        mov es, [es:HD_KG1]
.k:     mov al, [es:KG_E2F]
        mov [es:KG_FM3], al
        call sy_peak
        mov es, [es:1]
        loop .k
.nk:    pop es
        pop cx
        jmp .p
.d:     pop es
        popa
.r:     ret

; fxbuf (the menu code's) <- this level's text
sy_draw:
        push es
        mov ax, 0x3EA0
        mov es, ax
        mov di, LO_fxbuf
        mov cx, 32
.sp:    mov byte [es:di], ' '
        inc di
        loop .sp
        cmp byte [cs:sy_lvl], 0
        jne .pages
        mov di, LO_fxbuf          ; "SYN " + the program's name / "< ANALOG >    GO"
        mov word [es:di], 'SY'
        mov byte [es:di + 2], 'N'
        call sy_name
        mov di, LO_fxbuf + 16
        mov byte [es:di], '<'
        mov byte [es:di + 11], '>'
        mov word [es:di + 14], 'GO'
        mov al, [cs:sy_mode]
        mov ah, 8
        mul ah
        add ax, sy_mnames
        mov si, ax
        add di, 2
        mov cx, 8
        call sy_cpy
        jmp .r
.pages: cmp byte [cs:sy_mode], 0
        je .an
        cmp byte [cs:sy_mode], 1
        jne .soon
        call ch_draw
        jmp .r
.soon:
        mov di, LO_fxbuf          ; FAKE FM / WAVETABLE: soon
        mov al, [cs:sy_mode]
        mov ah, 8
        mul ah
        add ax, sy_mnames
        mov si, ax
        mov cx, 8
        call sy_cpy
        mov di, LO_fxbuf + 16
        mov si, sy_soon
        mov cx, 16
        call sy_cpy
        jmp .r
.an:    xor al, al
.f:     push ax
        call sy_one
        pop ax
        inc al
        cmp al, 4
        jb .f
.r:     pop es
        ret

; the program's name (12) at es:LO_fxbuf + 4, or "NO PROGRAM"
sy_name:
        push es
        call sy_prog1
        mov si, sy_nopr
        jz .np
        mov ax, es
        pop es
        push ds
        mov ds, ax
        mov si, 3
        mov di, LO_fxbuf + 4
        mov cx, 12
.c:     lodsb
        push bx
        mov bx, sy_akai
        cmp al, 41
        jb .ok
        mov al, 10
.ok:    cs xlatb
        pop bx
        mov [es:di], al
        inc di
        loop .c
        pop ds
        ret
.np:    pop es
        mov di, LO_fxbuf + 4
        mov cx, 10
        ; fall through
sy_cpy: mov al, [cs:si]           ; cx chars cs:si -> es:di
        mov [es:di], al
        inc si
        inc di
        loop sy_cpy
        ret

; field al of this page -> fxbuf: '>' if under the cursor, label (4), value (3)
sy_one: push ax
        mov ah, [cs:sy_cur]
        mov [cs:sy_tmp], ah
        mov [cs:sy_cur], al
        call sy_fld
        mov ah, [cs:sy_tmp]
        mov [cs:sy_cur], ah
        pop ax
        mov bl, [cs:si + 1]
        cmp bl, S_NONE
        je .r
        mov dl, [cs:si]
        xor dh, dh
        mov di, LO_fxbuf
        add di, dx
        mov ah, ' '
        cmp al, [cs:sy_cur]
        jne .m
        mov ah, '>'
.m:     mov [es:di], ah
        inc di
        push si
        add si, 6
        mov cx, 4
        call sy_cpy
        pop si
        call sy_get
        cmp ax, 0xFF
        je .na
        cmp bl, S_WAV
        je .wv
        cmp bl, S_KGS
        je .sg
        cmp bl, S_FEN
        je .sg
        jmp sy_d3
.na:    mov word [es:di], '--'
        mov byte [es:di + 2], '-'
.r:     ret
.wv:    mov ah, 3
        mul ah
        add ax, sy_wnames
        mov si, ax
        mov cx, 3
        jmp sy_cpy
.sg:    mov byte [es:di], '+'     ; signed: +nn / -nn
        or ax, ax
        jns .p
        mov byte [es:di], '-'
        neg ax
.p:     inc di
        mov bl, 10
        div bl
        add ax, '00'
        mov [es:di], ax
        ret

; ax = 0..999 -> 3 chars right-aligned at es:di
sy_d3:  mov cx, 3
        mov bx, 10
        add di, 2
.d:     xor dx, dx
        div bx
        add dl, '0'
        mov [es:di], dl
        dec di
        or ax, ax
        loopnz .d
        ret

sy_lvl:   db 0                    ; 0 the mode menu, 1 its pages
sy_pn:    db 0xFF                 ; the program count sy_fixrs last saw
sy_mode:  db 0
sy_page:  db 0
sy_cur:   db 0
sy_tmp:   db 0
sy_val:   db 0
sy_mnames: db "ANALOG  CHOP    FAKE FM WAVETBL "   ; (0.28: CHOP, src/rosetta_chop.asm)
sy_soon:  db "COMING NEXT     "
sy_nopr:  db "NO PROGRAM"
sy_wnames: db "SAWSQRPLSTRISIN"
sy_waves: db 0x1D, 0x0B, 0x21, 0x1D, 0x1B, 0x1C, 0x1A, 0x16, 0x1D, 0x1E, 0x1C, 0x13, 0x1D, 0x13, 0x18 ; (Akai chars)
sy_akai:  db "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ#+-."
SY_NP     equ 4
sy_fields:
        FLD 0, S_WAV, 0, 0, 4, "WAV "
        FLD 8, S_KG, KG_CUT, 0, 99, "CUT "
        FLD 16, S_KG, KG_RES, 0, 15, "RES "
        FLD 24, S_KGS, KG_KEY, -24, 24, "KEY "
        FLD 0, S_KG, KG_A1, 0, 99, "ATK "
        FLD 8, S_KG, KG_D1, 0, 99, "DEC "
        FLD 16, S_KG, KG_S1, 0, 99, "SUS "
        FLD 24, S_KG, KG_R1, 0, 99, "REL "
        FLD 0, S_FEN, KG_FM3, -50, 50, "FEN "
        FLD 8, S_KG, KG_E2R1, 0, 99, "F.AT"
        FLD 16, S_KG, KG_E2R3, 0, 99, "F.DC"
        FLD 24, S_KG, KG_E2L3, 0, 99, "F.SU"
        FLD 0, S_KG, KG_E2R4, 0, 99, "F.RL"
        FLD 8, S_PAR, 0, 0, 127, "DRF "
        FLD 16, S_PAR, 2, 0, 127, "DET "
        FLD 24, S_PAR, 3, 0, 127, "LFO "
