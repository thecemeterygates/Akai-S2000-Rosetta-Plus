; REV menu (0.24): MFX (EFFECTS on the SAMPLE page) with a REV type = the live reverse's own pages. Included by
; rosetta_hi.asm. The menu code only forwards (src/rosetta_fx.asm hi_rv, far call to header +1B, DS = 0):
;   ah = 0 draw (al != 0: to the LCD too), 1 = soft key al, 2 = value step al (wheel, signed)
;   CF = 1: not a REV type (the menu code does its FX page); else al = a TYPE step for the menu code to make
; Pages (PAGE up / down), knob (F1 / F2), value (wheel, GROUP up / down), EFFECTS = next type. The big knob's
; rocker (0.25, sent as keys 8 / 9 / 4 / 5): half push = previous / next knob straight over the pages, full = a page:
;   >REVERSE >IN  70    >FB   35>ATK  40    >STR   0>END  99    >PNG OFF>DRY  99
;   >1/8     >BPM  92   >REL  30>CMP  60    >OCT   0>TON  99    >SWL   0>SAV  OK
; SAV (0.25): any value step writes the knobs to the boot floppy (src/rosetta_knobs.asm); OK / ERR stays until
; the cursor or page moves.
; DIV is LEN (ms, 10 ms a step) while BPM is FREE (one below the slowest tempo).
RV_NP     equ 5
K_NONE    equ 0
K_TYPE    equ 1
K_IN      equ 2                   ; menu-code words (MFX IN, FX FB)
K_FB      equ 3
K_NUM     equ 4                   ; hi bytes
K_DIV     equ 5
K_BPM     equ 6
K_OCT     equ 7
K_ONOFF   equ 8
K_SAV     equ 9                   ; save the knobs (rosetta_knobs.asm)
RVF       equ 10                  ; field: pos (line x 16 + col), kind, var, min, max, label[4]

rv_ui:
        push bx
        push cx
        push dx
        push si
        push di
        push es
        call rv_fbsync
        push ax
        call rv_isrev
        pop ax
        jz .not
        cmp ah, 1
        je .key
        cmp ah, 2
        je .step
        call rv_draw
        xor al, al
        jmp .ok
.key:   call rv_key
        jmp .ok
.step:  call rv_step
.ok:    clc
        jmp .out
.not:   stc
.out:   pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        retf

; ZF = 0: the FX type is a REV one
rv_isrev:
        mov ax, MENU_SEG
        mov es, ax
        mov bl, [es:LO_fxon]
        xor bh, bh
        shl bx, 1
        shl bx, 1
        cmp byte [cs:rev_tab + bx], 0
        ret

; si = this page's field al (0-3)
rv_fld:
        push ax
        mov ah, [cs:rv_page]
        shl ah, 1
        shl ah, 1
        add al, ah
        mov ah, RVF
        mul ah
        add ax, rv_fields
        mov si, ax
        pop ax
        ret

; soft key al -> al = TYPE step (0 = none)
rv_key:
        cmp al, 0
        je .left
        cmp al, 1
        je .right
        cmp al, 4
        je .pdn
        cmp al, 5
        je .pup
        cmp al, 6
        je .dn
        cmp al, 7
        je .up
        cmp al, 8
        je .prev
        cmp al, 9
        je .next
        xor al, al
        ret
.next:  mov byte [cs:kn_st], 0xFF ; rocker: the next knob, onto the next page after the last
        mov cx, 4 * RV_NP
.n1:    mov al, [cs:rv_cur]
        inc al
        cmp al, 4
        jb .n2
        xor al, al
        mov ah, [cs:rv_page]
        inc ah
        cmp ah, RV_NP
        jb .n3
        xor ah, ah
.n3:    mov [cs:rv_page], ah
.n2:    mov [cs:rv_cur], al
        call rv_fld
        cmp byte [cs:si + 1], K_NONE
        loope .n1
        jmp .draw
.prev:  mov byte [cs:kn_st], 0xFF ; ... the previous one
        mov cx, 4 * RV_NP
.q1:    mov al, [cs:rv_cur]
        dec al
        jns .q2
        mov al, 3
        mov ah, [cs:rv_page]
        dec ah
        jns .q3
        mov ah, RV_NP - 1
.q3:    mov [cs:rv_page], ah
.q2:    mov [cs:rv_cur], al
        call rv_fld
        cmp byte [cs:si + 1], K_NONE
        loope .q1
        jmp .draw
.dn:    mov al, -1
        jmp rv_step
.up:    mov al, 1
        jmp rv_step
.pdn:   mov byte [cs:kn_st], 0xFF
        mov al, [cs:rv_page]
        dec al
        jns .p
        mov al, RV_NP - 1
        jmp .p
.pup:   mov byte [cs:kn_st], 0xFF
        mov al, [cs:rv_page]
        inc al
        cmp al, RV_NP
        jb .p
        xor al, al
.p:     mov [cs:rv_page], al
        call rv_fix               ; the cursor onto a knob that exists
        jmp .draw
.left:  mov byte [cs:kn_st], 0xFF
        mov cx, 4
.l1:    mov al, [cs:rv_cur]
        dec al
        and al, 3
        mov [cs:rv_cur], al
        call rv_fld
        cmp byte [cs:si + 1], K_NONE
        loope .l1
        jmp .draw
.right: mov byte [cs:kn_st], 0xFF
        mov cx, 4
.r1:    mov al, [cs:rv_cur]
        inc al
        and al, 3
        mov [cs:rv_cur], al
        call rv_fld
        cmp byte [cs:si + 1], K_NONE
        loope .r1
.draw:  mov al, 1
        call rv_draw
        xor al, al
        ret

rv_fix:
        mov cx, 4
.f:     mov al, [cs:rv_cur]
        call rv_fld
        cmp byte [cs:si + 1], K_NONE
        jne .r
        dec byte [cs:rv_cur]
        and byte [cs:rv_cur], 3
        loop .f
.r:     ret

; value step al (signed) on the knob under the cursor -> al = TYPE step (0 = none)
rv_step:
        mov dl, al
        mov al, [cs:rv_cur]
        call rv_fld
        mov bl, [cs:si + 1]
        cmp bl, K_TYPE
        jne .v
        mov al, dl                ; TYPE: the menu code steps it and draws again
        ret
.v:     cmp bl, K_SAV
        jne .v2
        cmp byte [cs:kn_st], 0    ; SAV: once (OK shows until the cursor moves: the wheel sends a few steps)
        je .vr
        mov byte [cs:kn_st], 0xFE
        mov al, 1                 ; "..." while the floppy works
        call rv_draw
        call kn_save
.vr:    mov al, 1
        call rv_draw
        xor al, al
        ret
.v2:    call rv_get               ; ax = value (signed for OCT)
        mov cl, dl
        mov ch, 0
        or cl, cl
        jns .a
        mov ch, 0xFF
.a:     add ax, cx
        mov cl, [cs:si + 4]       ; clamp to min / max (signed)
        mov ch, 0
        mov dl, [cs:si + 5]
        xor dh, dh
        cmp bl, K_OCT
        jne .m0
        mov ch, 0xFF              ; (OCT: min is -1)
.m0:    cmp bl, K_DIV
        jne .m1
        cmp byte [cs:lr_bpm], 0
        jne .m1
        mov cx, 5                 ; FREE: LEN 50-900 ms
        mov dx, 90
.m1:    cmp ax, cx
        jge .m2
        mov ax, cx
.m2:    mov cx, dx
        cmp ax, cx
        jle .m3
        mov ax, cx
.m3:    call rv_set
        mov al, 1
        call rv_draw
        xor al, al
        ret

; ax = the value of field si (kind bl)
rv_get:
        mov bp, [cs:si + 2]      ; (bp: di is the draw pointer)
        cmp bl, K_DIV
        jne .nd
        cmp byte [cs:lr_bpm], 0
        jne .nd
        mov ax, [cs:lr_lenms]     ; FREE: LEN / 10 ms
        mov cl, 10
        div cl
        xor ah, ah
        ret
.nd:    cmp bl, K_IN
        je .w
        cmp bl, K_FB
        je .w
        mov al, [cs:bp]
        xor ah, ah
        cmp bl, K_OCT
        jne .b
        cbw
.b:     cmp bl, K_BPM
        jne .r
        or al, al                 ; tempo 0 (= the preset's length) shows as one below the slowest
        jnz .r
        mov al, 39
.r:     ret
.w:     push es
        mov ax, MENU_SEG
        mov es, ax
        mov ax, [es:bp]
        pop es
        ret

; field si (kind bl) = ax
rv_set:
        mov bp, [cs:si + 2]      ; (bp: di is the draw pointer)
        cmp bl, K_DIV
        jne .nd
        cmp byte [cs:lr_bpm], 0
        jne .nd
        mov cl, 10                ; FREE: LEN
        mul cl
        mov [cs:lr_lenms], ax
        ret
.nd:    cmp bl, K_IN
        je .in
        cmp bl, K_FB
        je .fb
        cmp bl, K_BPM
        jne .b
        cmp al, 39
        jne .b
        xor al, al
.b:     mov [cs:bp], al
        ret
.fb:    push es
        mov dx, MENU_SEG
        mov es, dx
        mov [es:bp], ax
        pop es
        ret
.in:    push es                   ; MFX IN + its send word, as the menu code's setsend works it out
        mov dx, MENU_SEG
        mov es, dx
        mov [es:bp], ax
        or ax, ax
        jz .i
        mov dx, 255
        mul dx
        mov cx, 99
        div cx
        mov ah, al
        mov al, 0x0F
.i:     mov [es:LO_isendv], ax
        pop es
        ret

; draw this page into rv_buf; al != 0: and onto the LCD
rv_draw:
        push ax
        mov di, rv_buf
        mov cx, 32
.sp:    mov byte [cs:di], ' '
        inc di
        loop .sp
        xor al, al
.f:     push ax
        call rv_fld
        call rv_one
        pop ax
        inc al
        cmp al, 4
        jb .f
        pop ax
        or al, al
        jz .r
        mov al, 0x80              ; HD44780: line 1, line 2, cursor off (as fx_out)
        call rv_lcmd
        mov si, rv_buf
        call rv_l16
        mov al, 0xC0
        call rv_lcmd
        call rv_l16
        mov al, 0x0C
        call rv_lcmd
.r:     ret

; field si (number al on the page) -> rv_buf
rv_one:
        mov bl, [cs:si + 1]
        cmp bl, K_NONE
        je .r
        mov dl, [cs:si]
        xor dh, dh
        mov di, rv_buf
        add di, dx
        mov ah, ' '
        cmp al, [cs:rv_cur]
        jne .m
        mov ah, '>'
.m:     mov [cs:di], ah
        inc di
        cmp bl, K_TYPE
        je .type
        cmp bl, K_DIV
        je .div
        push si                   ; label (4; IN's 3: it sits at column 9)
        add si, 6
        mov cx, 4
        cmp bl, K_IN
        jne .lb
        dec cx
.lb:    mov ah, [cs:si]
        mov [cs:di], ah
        inc si
        inc di
        loop .lb
        pop si
        cmp bl, K_SAV
        je .sav
        call rv_get
        cmp bl, K_OCT
        je .oct
        cmp bl, K_ONOFF
        je .onoff
        cmp bl, K_BPM
        jne .num
        cmp al, 39
        jne .num
        mov word [cs:di - 4], 'FR'
        mov word [cs:di - 2], 'EE'
        ret
.num:   jmp rv_d3                 ; 3 digits, right-aligned
.oct:   mov word [cs:di], '  '
        mov byte [cs:di + 2], '0'
        or al, al
        jz .r
        mov byte [cs:di + 1], '+'
        mov byte [cs:di + 2], '1'
        jns .r
        mov byte [cs:di + 1], '-'
        ret
.sav:   mov al, [cs:kn_st]
        mov word [cs:di], '  '
        mov byte [cs:di + 2], ' '
        cmp al, 0xFF
        je .r
        mov word [cs:di], '..'
        mov byte [cs:di + 2], '.'
        cmp al, 0xFE
        je .r
        mov word [cs:di], ' O'
        mov byte [cs:di + 2], 'K'
        or al, al
        jz .r
        mov word [cs:di], 'ER'
        mov byte [cs:di + 2], 'R'
        ret
.onoff: mov word [cs:di], 'OF'
        mov byte [cs:di + 2], 'F'
        or al, al
        jz .r
        mov word [cs:di], ' O'
        mov byte [cs:di + 2], 'N'
        ret
.div:   cmp byte [cs:lr_bpm], 0   ; FREE: LEN ms
        jne .dn
        mov word [cs:di], 'LE'
        mov word [cs:di + 2], 'N '
        add di, 4
        mov ax, [cs:lr_lenms]
        jmp rv_d3
.dn:    mov al, [cs:lr_div]       ; 7 chars
        mov ah, 7
        mul ah
        add ax, rv_divn
        mov si, ax
        mov cx, 7
        jmp .cp
.type:  mov ax, MENU_SEG          ; the preset's name (8)
        mov es, ax
        mov bl, [es:LO_fxon]
        xor bh, bh
        shl bx, 1
        mov si, [cs:preset_ptrs + bx]
        sub si, LOREL
        mov cx, 8
.cp:    mov ah, [cs:si]
        mov [cs:di], ah
        inc si
        inc di
        loop .cp
.r:     ret

; ax = 0..999 -> 3 chars right-aligned at cs:di
rv_d3:
        mov cx, 3
        mov bx, 10
        add di, 2
.d:     xor dx, dx
        div bx
        add dl, '0'
        mov [cs:di], dl
        dec di
        or ax, ax
        loopnz .d
        ret

rv_lw:  push ax                   ; LCD busy flag at 0x62 bit 7, with a timeout
        push cx
        mov cx, 4000
.w:     in al, 0x62
        test al, 0x80
        loopnz .w
        pop cx
        pop ax
        ret
rv_lcmd:
        call rv_lw
        out 0x62, al
        ret
rv_l16: mov cx, 16                ; cs:si -> LCD data, si advanced
.l:     call rv_lw
        mov al, [cs:si]
        out 0x60, al
        inc si
        loop .l
        ret

rv_page:  db 0
rv_cur:   db 0
rv_buf:   times 32 db ' '
rv_divn:  db "1/16   1/8    1/8 DOT1/4    1/4 DOT"
%macro FLD 6                    ; pos, kind, var, min, max, label (4)
        db %1, %2
        dw %3
        db %4, %5, %6
%endmacro
rv_fields:
        FLD 0, K_TYPE, 0, 0, 0, "    "
        FLD 9, K_IN, LO_iwet, 0, 99, "IN  "
        FLD 16, K_DIV, lr_div, 0, 4, "LEN "
        FLD 24, K_BPM, lr_bpm, 39, 240, "BPM "
        FLD 0, K_FB, LO_pfb, 0, 99, "FB  "
        FLD 8, K_NUM, lr_att, 0, 99, "ATK "
        FLD 16, K_NUM, lr_rel, 0, 99, "REL "
        FLD 24, K_NUM, lr_comp, 0, 99, "CMP "
        FLD 0, K_NUM, lr_st, 0, 99, "STR "
        FLD 8, K_NUM, lr_en, 0, 99, "END "
        FLD 16, K_OCT, lr_oct, -1, 1, "OCT "
        FLD 24, K_NUM, lr_tone, 0, 99, "TON "
        FLD 0, K_ONOFF, lr_pp, 0, 1, "PNG "
        FLD 8, K_NUM, lr_dry, 0, 99, "DRY "
        FLD 16, K_NUM, lr_sw, 0, 99, "SWL "
        FLD 24, K_SAV, 0, 0, 0, "SAV "
        FLD 0, K_NUM, lf_bits, 4, 16, "BIT "    ; 0.28 (rosetta_plus.asm): LO-FI, MIDI clock
        FLD 8, K_NUM, lf_sh, 1, 16, "S&H "
        FLD 16, K_ONOFF, ck_on, 0, 1, "CLK "
        FLD 24, K_ONOFF, ck_lfo, 0, 1, "LFO "
