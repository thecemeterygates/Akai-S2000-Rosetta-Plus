; Saved knobs (0.25). Included by rosetta_hi.asm.
; The REV menu's SAV field writes the live-reverse knobs, the REV FB and MFX IN into kn_blk: the last 1 KB of the
; hi code, so it has its own block on the boot floppy inside the OS file's FAT chain (the OS never hands it out,
; tools/mkbaby.py) and the loader reads it in with the code at boot. hi_init takes the values if the magic is there.
; Raw write = the OS's raw read 1F50:00BB with two immediates flipped for the one call, the pair its own sector
; write (0FE4:A185) uses: DMA mode 4 -> 8 (memory to the FDC) and FDC block 6628 (46h READ DATA) -> 6631
; (45h WRITE DATA). Both share the tail at 662D (N, EOT, GPL, DTL); the DMA count (1 KB) ends it, as for reads.
%ifndef HI_BLOCK
HI_BLOCK  equ 273                 ; set by mkbaby.py
%endif
KN_BLOCK  equ HI_BLOCK + (kn_blk - $$) / 1024
KN_NB     equ ck_lfo + 1 - lr_bpm ; lr_bpm .. ck_lfo (0.28): one run of bytes in rosetta_lrev.asm
KO_N      equ 4                   ; block: "RKNB", KN_NB, 0, REV FB (w), MFX IN (w), the knob bytes
KO_FB     equ 6
KO_IN     equ 8
KO_LR     equ 10
RD_MODE   equ 0x0158              ; 1F50: `mov bh, 4` (DMA mode) immediate
RD_BLK    equ 0x0176              ; 1F50: `mov si, 6628h` (FDC command block) immediate

; boot: the saved knobs, if the block holds this layout
kn_load:
        cmp word [cs:kn_blk], 'RK'
        jne .r
        cmp word [cs:kn_blk + 2], 'NB'
        jne .r
        cmp byte [cs:kn_blk + KO_N], KN_NB
        jne .r
        mov si, kn_blk + KO_LR
        mov di, lr_bpm
        mov cx, KN_NB
.c:     mov al, [cs:si]
        mov [cs:di], al
        inc si
        inc di
        loop .c
        mov ax, [cs:kn_blk + KO_FB]
        mov [cs:lr_fbm], ax
        mov ax, [cs:kn_blk + KO_IN]
        mov si, rv_fields + RVF   ; MFX IN + its send word (the REV menu's IN field)
        mov bl, K_IN
        call rv_set
.r:     ret

; write the knobs to the floppy; kn_st = 0 OK, else an error (the OS call's al, or 1: the OS code isn't stock)
kn_save:
        mov word [cs:kn_blk], 'RK'
        mov word [cs:kn_blk + 2], 'NB'
        mov word [cs:kn_blk + KO_N], KN_NB
        push es
        mov ax, MENU_SEG
        mov es, ax
        mov ax, [es:LO_pfb]
        mov [cs:kn_blk + KO_FB], ax
        mov [cs:lr_fbm], ax
        mov ax, [es:LO_iwet]
        mov [cs:kn_blk + KO_IN], ax
        pop es
        mov si, lr_bpm
        mov di, kn_blk + KO_LR
        mov cx, KN_NB
.c:     mov al, [cs:si]
        mov [cs:di], al
        inc si
        inc di
        loop .c
        cmp byte [cs:lr_act], 0   ; live reverse off for it: no fill runs while the OS waits on the FDC
        je .w                     ; (lr_run starts it again on the next tick)
        call lr_stop
.w:     push ds
        mov ax, 0x1F50
        mov ds, ax
        mov al, 1
        cmp byte [RD_MODE], 4
        jne .x
        cmp word [RD_BLK], 0x6628
        jne .x
        mov byte [RD_MODE], 8     ; the raw read becomes a write
        mov word [RD_BLK], 0x6631
        pop ds
        mov ax, KN_BLOCK          ; block -> cylinder, head, sector (as the loader)
        mov bl, 20
        div bl
        mov cl, al
        mov dl, ah
        xor dh, dh
        cmp dl, 10
        jb .h0
        sub dl, 10
        inc dh
.h0:    inc dl
        mov ch, 3                 ; 1 KB sectors
        mov bx, 1024
        push cs
        pop es
        mov bp, kn_blk
        call 0x1F50:0x00BB
        push ds
        mov bx, 0x1F50
        mov ds, bx
        mov byte [RD_MODE], 4     ; a read again
        mov word [RD_BLK], 0x6628
.x:     pop ds
        mov [cs:kn_st], al
        ret

; REV FB memory: the menu code's type change sets FB to the preset's limit; picking a REV type gives the REV FB
; back (every tick + before the REV menu draws)
rv_fbsync:
        push ax
        push bx
        push es
        mov ax, MENU_SEG
        mov es, ax
        mov al, [es:LO_fxon]
        cmp al, [cs:kn_pfx]
        je .same
        mov [cs:kn_pfx], al
        call rv_isrev
        jz .r
        cmp word [cs:lr_fbm], 0xFFFF
        je .r
        mov ax, [cs:lr_fbm]
        mov [es:LO_pfb], ax
        jmp .r
.same:  call rv_isrev
        jz .r
        mov ax, [es:LO_pfb]
        mov [cs:lr_fbm], ax
.r:     pop es
        pop bx
        pop ax
        ret

kn_st:    db 0xFF                 ; SAV: FF idle, FE busy, 0 OK, else error
kn_pfx:   db 0                    ; the FX type last tick
lr_fbm:   dw 0xFFFF               ; the REV FB (FFFF: none yet)
