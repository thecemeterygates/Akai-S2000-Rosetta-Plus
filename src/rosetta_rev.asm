; REVERSE delay (0.22). Included by rosetta_hi.asm, runs from its tick (main loop, DS = 0).
;
; The voices' FX send is recorded by the chip's delay line: sample RAM words 0-FFFF, written at the position
; reg A fn 0 reports (2345:3294), measured on hw. Every 512 new samples are copied out with the OS's
; sample-RAM DMA (2345:1AA0), flipped here and written (2345:1AC8) into a buffer at the top of sample RAM.
; Each full chunk then plays forward (= the audio reversed) on one of two reserved voices, with 23 ms
; crossfades. On hw (0.21 lab), background DMA during notes left them clean.
;   CC 26 REVERSE   level, 0 = off
;   CC 27 REV TIME  chunk 0.09-0.73 s
;   CC 28 REV FDBK  the reversed sound back into the delay line (repeats, each one flipped again)
;   CC 29 REV OCT   64+ = an octave up (the chunk loops, so it plays twice, twice as fast)
; Works on top of any FX preset; with FX OFF it's a pure reverse (the voices still send into the line: lo's
; fxsend `je .r` is patched to nops while it runs).

REV_V0    equ 29              ; reverse voices: odd, because every sample-RAM DMA rewrites the even voices'
REV_V1    equ 27              ; start-address high bits (harmless for samples below 1M words, not for ours)
SL        equ 512             ; words per slice
FADE      equ 1024            ; crossfade (2 slices)
VOICES    equ 0x9F80          ; 2D95: voice table, 0x1BC each, +14D bit 0 = reserved (2345:7A49)

rev_run:
        call rev_params
        cmp byte [cs:rp_on], 0
        jnz .on
        cmp byte [cs:rv_act], 0
        je .r
        jmp rev_stop
.on:    cmp byte [cs:rv_act], 0
        jne .run
        call rev_start
.run:   call rev_reserve
        call 0x2345:0x3294    ; ax = delay line write position
        mov [cs:rv_w], ax
        call rev_voices
        mov ax, [cs:rv_w]
        sub ax, [cs:rv_cap]
        cmp ax, SL
        jb .r
        cmp ax, 0xC000        ; fell far behind (a disk load blocked the main loop): start over
        jae .rs
        jmp rev_slice
.rs:    mov ax, [cs:rv_w]
        and ax, ~(SL - 1)
        mov [cs:rv_cap], ax
        mov word [cs:rv_j], 0
.r:     ret

; rp_* from CC 26-29 (CC 26 > 0 = manual) or else from the FX page's preset (rev_tab in hi_fx.inc): its chunk
; scaled by the page's TIME %, and for REV ECHO the page's FEEDBACK % as the reverse repeats
rev_params:
        mov al, [cs:par + 6]
        or al, al
        jz .pre
        mov byte [cs:rp_on], 1
        xor ah, ah
        mov cl, 7
        shl ax, cl
        mov [cs:rp_lvl], ax
        mov al, [cs:par + 7]  ; chunk = 8..59 slices (0.09-0.69 s)
        xor ah, ah
        mov cx, 52
        mul cx
        mov cl, 7
        shr ax, cl
        add ax, 8
        mov [cs:rp_sl], ax
        mov al, [cs:par + 8]
        shl al, 1
        mov [cs:rp_fb], al
        mov al, [cs:par + 9]
        cmp al, 64
        sbb al, al
        inc al                ; 1 if >= 64
        mov [cs:rp_oct], al
        ret
.pre:   push es
        mov ax, MENU_SEG
        mov es, ax
        mov bl, [es:LO_fxon]
        xor bh, bh
        shl bx, 1
        shl bx, 1
        mov al, [cs:rev_tab + bx]
        cmp al, 1                 ; 0.28: kinds 2 / 3 (PITCH, SHIMMER, LO-FI) are the live input's only
        jbe .k1
        xor al, al
.k1:    mov [cs:rp_on], al
        or al, al
        jz .pd
        mov word [cs:rp_lvl], 100 << 7
        mov al, [cs:rev_tab + bx + 1]
        xor ah, ah
        mul word [es:LO_ptime]    ; TIME 25-200 %
        mov cx, 100
        div cx
        cmp ax, 8
        jae .t1
        mov ax, 8
.t1:    cmp ax, 60            ; chunk + FADE must stay < 0x8000: the chip's loop length is signed (hw:
        jbe .t2               ; 0x8000 played junk after the first lap)
        mov ax, 60
.t2:    mov [cs:rp_sl], ax
        mov ax, [es:LO_pfb]       ; FEEDBACK 0-99 -> send 0-247 (0.24: every REV type, the REV menu's FB)
        mov cl, 5
        mul cl
        shr ax, 1
        mov [cs:rp_fb], al
        xor al, al                ; octave up = the REV menu's OCT +1
        cmp byte [cs:lr_oct], 1
        jne .f
        inc al
.f:     mov [cs:rp_oct], al
.pd:    pop es
        ret

rev_start:
        mov byte [cs:rv_act], 1
        call 0x2345:0x3294
        and ax, ~(SL - 1)
        mov [cs:rv_cap], ax
        xor ax, ax
        mov [cs:rv_j], ax
        mov [cs:rv_st], ax    ; both voice slots idle
        mov [cs:rv_st + 2], ax
        push es               ; voices send into the line even with FX OFF: lo fxsend's `je .r` -> nop nop
        mov ax, MENU_SEG
        mov es, ax
        mov ax, [es:LO_fxsend + 6]
        cmp al, 0x74
        jne .s
        mov [cs:rv_je], ax
        mov word [es:LO_fxsend + 6], 0x9090
.s:     pop es
        ret

rev_stop:
        mov byte [cs:rv_act], 0
        mov bl, REV_V0
        call vfade
        mov bl, REV_V1
        call vfade
        push es
        mov ax, MENU_SEG
        mov es, ax
        mov ax, [cs:rv_je]
        or ax, ax
        jz .s
        mov [es:LO_fxsend + 6], ax
.s:     mov ax, 0x2D95        ; free the voices (they fade out on their own)
        mov es, ax
        and byte [es:VOICES + REV_V0 * 0x1BC + 0x14D], 0xFE
        and byte [es:VOICES + REV_V1 * 0x1BC + 0x14D], 0xFE
        pop es
        ret

rev_reserve:                  ; keep the OS off our voices (its all-notes-off clears the flags)
        push es
        mov ax, 0x2D95
        mov es, ax
        or byte [es:VOICES + REV_V0 * 0x1BC + 0x14D], 1
        or byte [es:VOICES + REV_V1 * 0x1BC + 0x14D], 1
        pop es
        ret

; one slice: line[cap, cap+SL) flipped into buf[C - (j+1)SL]; on a chunk's first slice also the FADE samples
; before it (its crossfade tail, at buf[C..C+FADE)); after the last slice the chunk plays
rev_slice:
        cmp word [cs:rv_j], 0
        jne .s1
        mov ax, [cs:rp_sl]
        mov [cs:rv_nsl], ax
        mov cl, 9
        shl ax, cl            ; * SL
        mov [cs:rv_c], ax
        mov ax, [cs:rv_cap]
        sub ax, SL
        mov bx, [cs:rv_c]
        call rev_copy
        mov ax, [cs:rv_cap]
        sub ax, 2 * SL
        mov bx, [cs:rv_c]
        add bx, SL
        call rev_copy
.s1:    mov ax, [cs:rv_j]
        inc ax
        mov cl, 9
        shl ax, cl
        mov bx, [cs:rv_c]
        sub bx, ax            ; C - (j+1)SL
        mov ax, [cs:rv_cap]
        call rev_copy
        add word [cs:rv_cap], SL
        inc word [cs:rv_j]
        mov ax, [cs:rv_j]
        cmp ax, [cs:rv_nsl]
        jb .r
        mov word [cs:rv_j], 0
        call rev_play
.r:     ret

; ax = line address, bx = word offset in the current buffer: copy SL words, flipped (keeps the OS DMA pointer)
rev_copy:
        push word [0x78E4]
        push word [0x78E6]
        push bx
        mov [0x78E4], ax
        mov word [0x78E6], 0
        mov cx, SL
        mov dx, LABBUF
        xor di, di
        call 0x2345:0x1AA0    ; delay line -> LABBUF:0000
        push ds
        mov ax, LABBUF
        mov ds, ax
        xor si, si
        mov di, (SL - 1) * 2
        mov cx, SL / 2
.f:     mov ax, [si]
        mov dx, [di]
        mov [si], dx
        mov [di], ax
        add si, 2
        sub di, 2
        loop .f
        pop ds
        pop bx
        mov [0x78E4], bx
        mov al, [cs:rv_k]
        and al, 1
        add al, 0xFE          ; buffer A = word FE0000, B = FF0000
        xor ah, ah
        mov [0x78E6], ax
        mov cx, SL
        mov dx, LABBUF
        xor si, si
        call 0x2345:0x1AC8    ; LABBUF:0000 -> buffer
        pop word [0x78E6]
        pop word [0x78E4]
        ret

; the finished chunk (buffer k & 1) starts on voice slot k & 1, fading in
rev_play:
        mov al, [cs:rv_k]
        and al, 1
        mov bl, REV_V0
        jz .v
        mov bl, REV_V1
.v:     xor ah, ah
        mov si, ax
        shl si, 1
        mov ax, [cs:rv_w]
        mov [cs:rv_ws + si], ax
        mov ax, [cs:rv_c]
        mov [cs:rv_cl + si], ax
        mov byte [cs:rv_st + si], 1
        mov al, [cs:rv_k]
        and al, 1
        add al, 0xFE
        mov [cs:vs_hi], al
        mov ax, [cs:rv_c]
        add ax, FADE
        mov [cs:vs_len], ax
        mov ax, 0x1000
        cmp byte [cs:rp_oct], 0
        je .p
        mov ax, 0x2000        ; octave up: the chunk loops, so it plays twice
.p:     mov [cs:vs_rate], ax
        mov ax, [cs:rp_lvl]
        mov [cs:vs_lvl], ax
        mov al, [cs:rp_fb]
        xor ah, ah
        or al, al
        jz .fb
        mov ah, al
        mov al, 0x0F          ; send level << 8 | dest 0xF (delay line)
.fb:    mov [cs:vs_send], ax
        mov word [cs:vs_lr], 0x7D7E
        call vstart
        inc byte [cs:rv_k]
        ret

; fade out a slot's voice C samples after its start; mark it idle after the fade
rev_voices:
        xor si, si
.l:     mov al, [cs:rv_st + si]
        or al, al
        jz .n
        mov ax, [cs:rv_w]
        sub ax, [cs:rv_ws + si]
        cmp byte [cs:rv_st + si], 1
        jne .f2
        cmp ax, [cs:rv_cl + si]
        jb .n
        mov byte [cs:rv_st + si], 2
        mov bl, REV_V0
        or si, si
        jz .fv
        mov bl, REV_V1
.fv:    call vfade
        jmp .n
.f2:    mov dx, [cs:rv_cl + si]
        add dx, 2 * FADE
        cmp ax, dx
        jb .n
        mov byte [cs:rv_st + si], 0
.n:     add si, 2
        cmp si, 4
        jb .l
        ret

; chip voice bl: start a one-shot at word address vs_hi:0000 (vs_len words), rate, envelope level, send word.
; Same register order as the OS note-on (emulator trace): reg3, 1, 7, DFL, 5, 6, 4, 8, 9, 0, 2, 1, key on.
%macro VSEL 1
        mov ah, %1
        mov al, bl
        out 0x80, ax
%endmacro
vstart:
        VSEL 3
        xor ax, ax
        out 0x8C, ax          ; env value 0
        VSEL 7
        mov ax, [cs:vs_lr]    ; L / R volume
        out 0x82, ax
        mov ax, [cs:vs_send]
        out 0x84, ax
        mov ah, 2             ; second filter bank (DFL), as the OS sets it
        mov al, bl
        out 0xE0, ax
        xor ax, ax
        out 0xE2, ax
        out 0xE4, ax
        VSEL 5
        mov ax, 0x3FFF
        out 0x84, ax
        mov ah, 4
        mov al, bl
        out 0xE0, ax
        mov ax, 0x20
        out 0xE4, ax
        VSEL 6
        xor ax, ax
        out 0x82, ax
        mov ax, 0x7FF0
        out 0x84, ax
        mov ah, 1
        mov al, bl
        out 0xE0, ax
        mov ax, 0x8000
        out 0xE4, ax
        xor ax, ax
        out 0xE2, ax
        VSEL 4
        mov ax, [cs:vs_lvl]
        out 0x84, ax
        shr ax, 1
        shr ax, 1             ; rate: 0 -> level in FADE samples (8.8 per sample)
        out 0x82, ax
        VSEL 8
        xor ax, ax
        out 0x8C, ax
        VSEL 9
        xor ax, ax
        out 0x8C, ax
        VSEL 0                ; start = hi:0000
        mov al, [cs:vs_hi]
        mov ah, 0
        mov dx, ax
        mov cl, 4
        shr ax, cl
        or ax, 0x0100
        out 0x86, ax
        mov ax, dx
        mov cl, 12
        shl ax, cl
        out 0x84, ax
        xor ax, ax
        out 0x82, ax
        VSEL 2                ; loop multiplier -1.0, loop = the whole chunk
        mov ax, 0xF000
        out 0x84, ax
        mov ax, [cs:vs_len]
        out 0x82, ax
        VSEL 1                ; rate, end = hi:len (bits 23-20 / 19-4, relative loop)
        mov ax, [cs:vs_rate]
        out 0x82, ax
        mov al, [cs:vs_hi]
        mov ah, 0
        mov dx, ax
        mov cl, 4
        shr ax, cl
        out 0x86, ax
        mov ax, dx
        mov cl, 12
        shl ax, cl
        mov dx, [cs:vs_len]
        mov cl, 4
        shr dx, cl
        or ax, dx
        out 0x84, ax
        in ax, 0x88           ; key on the selected voice, as the OS does it
        and ax, 0x7F
        or ax, 0x100
        out 0x88, ax
        ret

vfade:                        ; voice bl: envelope to 0 in about FADE samples. Rate bit 15 = going down (the OS
        VSEL 4                ; ramps down with rates FA24/ED00/F000, up with 082C; without it nothing moves)
        xor ax, ax
        out 0x84, ax
        mov ax, [cs:vs_lvl]
        shr ax, 1
        shr ax, 1
        or ax, ax
        jnz .r
        mov ax, 0x1000
.r:     or ax, 0x8000
        out 0x82, ax
        ret

rv_act:   db 0
rv_k:     db 0
rv_je:    dw 0
rv_w:     dw 0
rv_cap:   dw 0
rv_j:     dw 0
rv_nsl:   dw 0
rv_c:     dw 0
rv_st:    dw 0, 0             ; per slot: 0 idle, 1 playing, 2 fading
rv_ws:    dw 0, 0             ; write position at its start
rv_cl:    dw 0, 0             ; its chunk length
vs_hi:    db 0
vs_len:   dw 0
vs_rate:  dw 0
vs_lvl:   dw 0
vs_send:  dw 0
vs_lr:    dw 0x7D7E
rp_on:    db 0                ; this tick's reverse settings (rev_params)
rp_oct:   db 0
rp_fb:    db 0                ; send byte back into the line (0 = none)
rp_sl:    dw 0                ; chunk in 512-sample slices
rp_lvl:   dw 0                ; voice envelope level
