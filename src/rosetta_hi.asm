; Rosetta hi code: CPU RAM 4000:0000-FFFF (64 KB the OS never touches), stored on the boot floppy right
; after the 256 KB OS file and read in after boot by src/rosetta_load.asm. Room for the big features.
;
; The OS is all RAM, so hi_init hooks it at run time (patch table below, every stock byte checked first):
; nothing points at the hi code unless it really loaded. The OS hooks call fixed slots in the header, so a
; new build can be sent into a running S2000 over SysEx (tools/hiload.py): the loader's tick is parked,
; the blob uploaded, the hooks re-pointed from the blob's patch table, and its tick runs `apply` itself.
;
; SYNTH basics (0.20), per voice, all 0 = exactly stock:
;   CC 20 DRIFT     analog-style slow random pitch wander, up to +-20 cents
;   CC 21 DRIFT SPD how fast it wanders
;   CC 22 DETUNE    fixed per-voice detune spread, up to +-25 cents (voices rotate, so every note differs)
;   CC 23 FLT LFO   filter LFO depth: the cutoff dips from where the program sets it and comes back (on hw,
;                   127 = down ~2000 log steps, highs -30 dB+; the top ~800 steps of an open filter are inaudible)
;   CC 24 LFO RATE  0.03-10 Hz
;   CC 25 LFO SPRD  per-voice LFO phase spread (0 = all voices together, 127 = all different)
; REVERSE delay (0.22, src/rosetta_rev.asm): CC 26 level (0 = off), 27 time, 28 feedback, 29 octave up.
; MFX input FX (0.24): on the sampling screen the OS plays the input back on voices 15h / 17h (its monitor);
; mfx_run sets their FX send to the MFX page's IN level (lo isendv), so the input runs through the FX.
; Hooks: 2345:5611 (every pitch write: note-on + the ~15 ms update, pitch = semitone * 256) and 2345:59CD
; (every cutoff target, log 0-FFF, the chip glides to it), 2B9D:01AE (MIDI CC in, any channel).
        cpu 186
        bits 16
        org 0
%ifndef HI_VERSION
HI_VERSION equ 0
%endif
HI_SEG    equ 0x4000
MENU_SEG  equ 0x3EA0          ; the menu code (lo): its offsets past LOREL are this hi RAM
LOREL     equ (HI_SEG - MENU_SEG) * 16
POPUP     equ 0x8FE0          ; OS popup text buffer in segment 0 (2 x 16 chars + FF)
NVOICE    equ 32
CC_FIRST  equ 20
NCC       equ 12              ; CC 20-31
RETF_2345 equ 0x27CB          ; a retf in segment 2345 (near-call trick)

        db "RSHI"             ; +0 magic
        dw HI_VERSION         ; +4
        jmp near hi_init      ; +6 once, right after loading
        jmp near hi_tick      ; +9 every main-loop tick: keep all registers
        jmp near pitch_in     ; +C  from 2345:5611
        jmp near cut_tgt      ; +F  from 2345:59CD
        jmp near cc_in        ; +12 from 2B9D:01AE
        dw patches            ; +15 for tools/hiload.py
        dw mbox               ; +17 lab mailbox (reverse-delay research, run from the tick)
        dw par                ; +19 the CC 20-29 values (lab)
        jmp near rv_ui        ; +1B the REV menu (src/rosetta_rvui.asm), from the menu code's MFX page
        jmp near syn_ui       ; +1E the SYNTH page (src/rosetta_synui.asm), MULTI

hi_init:
        pusha
        push es
        call apply
        call hi_setup
        call kn_load          ; the knobs saved on the floppy (REV menu SAV)
        mov byte [cs:inited], 1
        mov si, msg_ok
        cmp byte [cs:pfail], 0
        je .m
        mov si, msg_pf
.m:     call popup
        pop es
        popa
        retf

; the menu code's FX page uses our FX bank (tools/fxbank.py -> hi_fx.inc) from now on
hi_setup:
        push es
        mov ax, MENU_SEG
        mov es, ax
        mov word [es:LO_fxhdr], hifx + LOREL
        pop es
        ret

; patch table: dw seg, off / db n / n stock bytes / n new bytes; seg 0 ends it
apply:  mov si, patches
.p:     mov ax, [cs:si]
        or ax, ax
        jz .r
        mov es, ax
        mov di, [cs:si + 2]
        mov cl, [cs:si + 4]
        xor ch, ch
        add si, 5
        push si
        push di
        push cx
.cmp:   mov al, [cs:si]
        cmp al, [es:di]
        jne .bad
        inc si
        inc di
        loop .cmp
        pop cx
        pop di
        pop si
        add si, cx
.cp:    mov al, [cs:si]
        mov [es:di], al
        inc si
        inc di
        loop .cp
        jmp .p
.bad:   pop cx                ; not stock: fine if it already holds our bytes (hot reload)
        pop di
        pop si
        push si
        push di
        push cx
        add si, cx
.cmp2:  mov al, [cs:si]
        cmp al, [es:di]
        jne .bad2
        inc si
        inc di
        loop .cmp2
        pop cx
        pop di
        pop si
        add si, cx
        add si, cx
        jmp .p
.bad2:  pop cx
        pop di
        pop si
        add si, cx
        add si, cx
        mov byte [cs:pfail], 1
        jmp .p
.r:     ret

patches:
        dw 0x2345, 0x5611     ; push cs / call 52A3 / add ax,[si+0B6h]  ->  pitch_in
        db 8
        db 0x0E, 0xE8, 0x8E, 0xFC, 0x03, 0x84, 0xB6, 0x00
        db 0x9A
        dw 0x000C, HI_SEG
        db 0x90, 0x90, 0x90
        dw 0x2345, 0x59CD     ; call 59A5 / mov dx,ax  ->  cut_tgt
        db 5
        db 0xE8, 0xD5, 0xFF, 0x8B, 0xD0
        db 0x9A
        dw 0x000F, HI_SEG
        dw 0x2B9D, 0x01AE     ; cmp dl,7Ah / jb 01E0  ->  cc_in
        db 5
        db 0x80, 0xFA, 0x7A, 0x72, 0x2D
        db 0x9A
        dw 0x0012, HI_SEG
        dw 0

; ---------------------------------------------------------------------------------------------
; 2345:5611: ax = pitch (semitone * 256), bl = voice. Stock: push cs / call 52A3 (pitch -> chip rate) /
; add ax,[si+0B6h] (fine offset on the rate).
pitch_in:
        push bx
        and bx, NVOICE - 1
        shl bx, 1
        add ax, [cs:poff + bx]
        pop bx
        call 0x2345:0x52A3
        add ax, [si + 0xB6]
        retf

; 2345:59CD: the cutoff target (log 0-FFF) for voice bl, then dx = it. Stock: call 59A5 / mov dx,ax.
cut_tgt:
        push cs
        push .back
        push RETF_2345
        jmp 0x2345:0x59A5     ; near routine: its ret lands on the retf at 2345:27CB
.back:  push bx
        and bx, NVOICE - 1
        shl bx, 1
        mov bx, [cs:coff + bx]
        or bx, bx
        jz .s                 ; no LFO on this voice: exactly stock
        add ax, bx
        jns .l
        xor ax, ax
.l:     cmp ax, 0x0FFF
        jbe .s
        mov ax, 0x0FFF
.s:     pop bx
        mov dx, ax
        retf

; 2B9D:01AE: control change, dl = controller, dh = value. Ours are kept (the stock code still sees them).
; Stock: cmp dl,7Ah / jb 01E0 (else 01B3).
cc_in:  push bp
        mov bp, sp
        cmp dl, CC_FIRST
        jb .stock
        cmp dl, CC_FIRST + NCC
        jae .stock
        push bx
        mov bl, dl
        sub bl, CC_FIRST
        xor bh, bh
        mov [cs:par + bx], dh
        pop bx
.stock: mov word [bp + 2], 0x01E0
        cmp dl, 0x7A
        jb .r
        mov word [bp + 2], 0x01B3
.r:     pop bp
        retf

; ---------------------------------------------------------------------------------------------
; every main-loop tick: advance the LFO + drift by the OS ticks since the last call (0.511 ms each), recompute the
; per-voice offsets
hi_tick:
        pusha
        push es
        cmp byte [cs:inited], 0
        jne .go
        mov byte [cs:inited], 1   ; sent in over SysEx: hook the OS ourselves
        call apply
        call hi_setup
.go:    cmp byte [cs:ch_busy], 0  ; 0.28: CHOP is building (the OS's busy loop may come back here): idle
        je .go1
        jmp .out
.go1:   call ch_tick          ; CHOP's lazy capture
        call rv_fbsync
        call plus_tick        ; 0.28: MIDI clock, LOOPER freeze (rosetta_plus.asm)
        call sy_fixrs         ; ROSETTA ROM programs: the filter env as the S2000 wants it
        inc word [cs:npass]       ; lab: passes + the longest gap in OS ticks (how often the FX LFO runs)
        call 0x2345:0x0A47
        mov ah, al
        sub ah, [cs:ptick]
        mov [cs:ptick], al
        cmp ah, [cs:maxgap]
        jbe .g
        mov [cs:maxgap], ah
.g:     cmp byte [cs:mbox], 0
        je .nomb
        call lab_cmd
.nomb:  cmp word [cs:hammer], 0
        je .noh
        dec word [cs:hammer]      ; lab: one 256-word sample-RAM read per main-loop pass (voice glitch test)
        mov word [0x78E4], 0
        mov word [0x78E6], 0
        mov cx, 256
        mov dx, LABBUF
        xor di, di
        call 0x2345:0x1AA0
.noh:   cmp byte [0x762B], 4      ; SAMPLE page (incl. armed / recording): the OS records through the same
        jne .dma                  ; sample-RAM DMA, so reverse + live stop here (they hung it on hw 0.23)
        cmp byte [cs:rv_act], 0
        je .nr
        call rev_stop
.nr:    call lr_run
        call mfx_run
        jmp .ndma
.dma:   mov byte [cs:lr_act], 0   ; off the SAMPLE page the OS has stopped the input (live reverse included)
        call rev_run
.ndma:
        call 0x2345:0x0A47    ; al = tick
        mov ah, al
        sub ah, [cs:lasttick]
        jz .out
        mov [cs:lasttick], al
        mov cl, ah            ; ticks since the last run
        xor ch, ch
        mov [cs:nt], cl
        ; filter LFO phase: inc = 1 + rate^2 / 48 per tick (OS tick [73DA] = 0.511 ms on hw, 1957 Hz:
        ; 0.03-10 Hz)
        mov al, [cs:par + 4]
        mul al
        mov bx, 48
        xor dx, dx
        div bx
        inc ax
        mul cx
        add [cs:lphase], ax
        ; drift: now and then one voice gets a new random target (every 160 ticks slow .. 33 fast, so each
        ; voice every ~2.6 .. 0.55 s); every 32 ticks (16 ms) all voices slew toward theirs
        add [cs:racc], cl
        mov al, [cs:par + 1]
        neg al
        add al, 160
        cmp [cs:racc], al
        jb .d1
        mov byte [cs:racc], 0
        call rnd
        sar ax, 1             ; Q14: tgt - pos can't overflow
        mov bx, [cs:dnext]
        inc word [cs:dnext]
        and bx, NVOICE - 1
        shl bx, 1
        mov [cs:dtgt + bx], ax
.d1:    add [cs:dacc], cl
        cmp byte [cs:dacc], 32
        jb .calc
        mov byte [cs:dacc], 0
        mov si, 0             ; pos += (tgt - pos) >> shift: 7 (~2 s) slow .. 4 (~0.25 s) fast
        mov cl, [cs:par + 1]
        shr cl, 5             ; 0..3
        neg cl
        add cl, 7             ; 7..4
.sl:    mov ax, [cs:dtgt + si]
        sub ax, [cs:dpos + si]
        sar ax, cl
        add [cs:dpos + si], ax
        add si, 2
        cmp si, 2 * NVOICE
        jb .sl
.calc:  mov al, [cs:nt]        ; per-voice offsets every 8 ticks (4 ms; the OS updates a voice every ~15 ms),
        add [cs:cacc], al     ; and not at all while every control is 0 (after one pass that zeroes them)
        cmp byte [cs:cacc], 8
        jb .out
        mov byte [cs:cacc], 0
        mov al, [cs:par + 0]
        or al, [cs:par + 2]
        or al, [cs:par + 3]
        mov ah, al
        or al, [cs:cbusy]
        jz .out
        mov [cs:cbusy], ah
        xor si, si            ; voice * 2
.v:     ; pitch offset = drift pos (Q14) * drift amt, scaled to +-50 units, + detune tab * detune amt / 256
        mov ax, [cs:dpos + si]
        mov bl, [cs:par + 0]
        xor bh, bh
        imul bx               ; dx:ax = pos * amt (Q14 * 0..127)
        mov ax, dx            ; >> 16: +-31
        mov bx, 51
        imul bx
        sar ax, 5             ; +-50 units = +-20 cents
        mov di, ax
        mov bx, si
        shr bx, 1
        mov al, [cs:dtab + bx]
        cbw
        mov bl, [cs:par + 2]
        xor bh, bh
        imul bx               ; -128..127 * 0..127
        sar ax, 8             ; +-63 units = +-25 cents
        add ax, di
        mov [cs:poff + si], ax
        ; cutoff offset = sin(phase + voice spread) * depth * 8 (log units)
        xor ax, ax
        mov bl, [cs:par + 3]
        or bl, bl
        jz .c0
        mov ax, si
        shr ax, 1
        mov bh, [cs:par + 5]
        mul bh                ; voice * spread (0..31 * 127)
        shl ax, 3             ; spread 127: voices spaced ~1/8 turn
        add ax, [cs:lphase]
        mov bl, ah            ; 256-step table
        xor bh, bh
        shl bx, 1
        mov ax, [cs:hsin + bx]    ; Q14
        sub ax, 16384         ; -32768..0: the cutoff dips from the set value and comes back
        mov bl, [cs:par + 3]
        xor bh, bh
        shl bx, 4             ; depth * 16: down to -2032
        imul bx
        shl ax, 1
        rcl dx, 1
        mov ax, dx            ; >> 15
.c0:    mov [cs:coff + si], ax
        add si, 2
        cmp si, 2 * NVOICE
        jb .v
.out:   inc word [cs:ticks]
        pop es
        popa
        retf

; ---------------------------------------------------------------------------------------------
; lab mailbox (poked over SysEx, run here in the main loop): cmd 1 = read [count] words of sample RAM from
; [addr] into LABBUF:0000, 2 = write them back from there, 3 = delay-line write position -> result.
; t0/t1 = OS tick before/after (0.511 ms each).
LABBUF    equ 0x4800          ; lab / reverse scratch (4 KB at 0x48000): above the code + tables (0.24 fix: at 0x4100
                              ; it overlapped sintab / hsin / dtab once the blob passed 4 KB, so REV slices wrote audio
                              ; into the chorus sine table). mkbaby.py checks the blob stays below it.
SCANBUF   equ 0x4900          ; lab cmd 4 peaks
TONE_V    equ 25              ; lab test tone voice (odd: see rosetta_rev.asm)
lab_cmd:
        call 0x2345:0x0A47
        mov [cs:mb_t0], al
        mov al, [cs:mbox]
        cmp byte [0x762B], 4      ; SAMPLE page: the sample-RAM DMA (cmds 1, 2, 4, 5) borrows voice 0 = the
        jne .ok                   ; input writer and breaks the OS's input mode (hw 0.24): refused, res = FFFF
        cmp al, 6
        jae .ok
        cmp al, 3
        je .ok
        mov word [cs:mb_res], 0xFFFF
        jmp .done
.ok:
        cmp al, 3
        je .pos
        cmp al, 4
        je .scan
        cmp al, 5
        jne .c6
        mov ax, [cs:mb_count]     ; cmd 5: hammer for [count] main-loop passes
        mov [cs:hammer], ax
        jmp .done
.c6:    cmp al, 9                 ; cmd 9: DMA channel [count] current address + count -> res, res2
        jne .c8                   ; (V53 DMAU: channel select C001, address C004, count C002)
        pushf
        cli
        mov dx, 0xC001
        in al, dx
        push ax
        mov al, [cs:mb_count]
        out dx, al
        mov dx, 0xC004
        in ax, dx
        mov [cs:mb_res], ax
        mov dx, 0xC001
        mov al, [cs:mb_count + 1]
        out dx, al
        mov dx, 0xC004
        in ax, dx
        mov [cs:mb_res2], ax
        pop ax
        mov dx, 0xC001
        out dx, al
        popf
        jmp .done
.c8:    cmp al, 8                 ; cmd 8: test tone on voice 25 (count = loop words at sample RAM word
        jne .c67                  ; addr, a whole chunk looping, FX send = the FX page WET) / count 0 = off
        mov bl, TONE_V
        mov ax, [cs:mb_count]
        or ax, ax
        jz .toff
        mov [cs:vs_len], ax
        mov al, [cs:mb_addr + 2]
        mov [cs:vs_hi], al
        mov word [cs:vs_rate], 0x1000
        mov word [cs:vs_lvl], 0x3F80
        mov word [cs:vs_lr], 0x6060
        push es
        mov ax, MENU_SEG
        mov es, ax
        mov ax, [es:LO_fxsendv]
        mov [cs:vs_send], ax
        mov ax, 0x2D95
        mov es, ax
        or byte [es:VOICES + TONE_V * 0x1BC + 0x14D], 1
        pop es
        pushf
        cli
        call vstart
        popf
        jmp .done
.toff:  mov word [cs:vs_lvl], 0x3F80
        pushf
        cli
        call vfade
        popf
        push es
        mov ax, 0x2D95
        mov es, ax
        and byte [es:VOICES + TONE_V * 0x1BC + 0x14D], 0xFE
        pop es
        jmp .done
.c67:   cmp al, 6                 ; cmd 6 / 7: chip register write / read, atomic: select = addr low word
        jb .rw                    ; (reg << 8 | voice), port = addr high word, value = count / -> res
        cmp al, 7
        ja .rw
        mov dx, [cs:mb_addr + 2]
        mov bx, [cs:mb_count]
        pushf
        cli
        push ax
        mov ax, [cs:mb_addr]
        out 0x80, ax
        pop ax
        cmp al, 6
        jne .cr
        mov ax, bx
        out dx, ax
        jmp .cw
.cr:    in ax, dx
        mov [cs:mb_res], ax
.cw:    popf
        jmp .done
.rw:    mov ax, [cs:mb_addr]
        mov [0x78E4], ax          ; OS sample-RAM DMA pointer (DS = 0 here)
        mov ax, [cs:mb_addr + 2]
        mov [0x78E6], ax
        mov cx, [cs:mb_count]
        mov dx, LABBUF
        xor di, di
        xor si, si
        cmp byte [cs:mbox], 1
        jne .wr
        call 0x2345:0x1AA0        ; sample RAM -> DX:DI, cx words
        jmp .done
.wr:    call 0x2345:0x1AC8        ; DX:SI -> sample RAM
        jmp .done
.pos:   call 0x2345:0x3294        ; ax = delay line write position (reg A fn 0)
        mov [cs:mb_res], ax
        jmp .done
.scan:  ; cmd 4: [count] chunks of 2048 words from [addr]: peak |sample| >> 8 of each -> SCANBUF:0000.. (1 byte each)
        mov ax, [cs:mb_addr]
        mov [0x78E4], ax
        mov ax, [cs:mb_addr + 2]
        mov [0x78E6], ax
        xor bp, bp
.sc:    cmp bp, [cs:mb_count]
        jae .done
        mov cx, 2048
        mov dx, LABBUF
        xor di, di
        call 0x2345:0x1AA0        ; advances [78E4]:[78E6]
        push ds
        mov ax, LABBUF
        mov ds, ax
        xor si, si
        mov cx, 2048
        xor bx, bx
.pk:    lodsw
        or ax, ax
        jns .p1
        neg ax
.p1:    cmp ax, bx
        jbe .p2
        mov bx, ax
.p2:    loop .pk
        pop ds
        mov ax, SCANBUF
        mov es, ax
        mov [es:bp], bh
        inc bp
        jmp .sc
.done:  call 0x2345:0x0A47
        mov [cs:mb_t1], al
        mov byte [cs:mbox], 0
        ret

; sampling screen (mode 4): the OS's input monitor voices 15h / 17h (2345:3078, templates 2D95:3894 / 38C0,
; reg 7 word 1 = 0) get the MFX IN send, every pass (the OS rewrites them on input start / MONITOR changes).
; FX OFF = 0 = stock. Hw 0.23 lab: send 40h with ECHO = the input echoes.
mfx_run:
        push es
        mov ax, MENU_SEG
        mov es, ax
        xor ax, ax
        cmp byte [es:LO_fxon], 0
        je .w
        mov ax, [es:LO_isendv]
        or ax, ax
        jz .w
        mov al, ah            ; IN 99 = send 66h (hw 0.24: guitar at IN 66 = send AAh clipped the chorus /
        xor ah, ah            ; flanger taps = fizz; IN 20 = 33h was almost clean)
        shl ax, 1
        mov dl, 5
        div dl
        mov ah, al
        mov al, 0x0F
.w:     pop es
        mov bx, ax
        call fz_in            ; 0.28: frozen LOOPER: no input into it
        cmp byte [cs:lr_act], 0
        jne .lr
        xor cx, cx            ; 17h (R) only in stereo: in mono its 128-sample ring is never written and it
        test byte [0x7500], 1 ; loops stale data = a steady ~344 Hz tone into the FX (hw 0.24)
        jz .m
        mov cx, ax
.m:     pushf
        cli
        mov ax, 0x0715
        out 0x80, ax
        mov ax, bx
        out 0x84, ax
        mov ax, 0x0717
        out 0x80, ax
        mov ax, cx
        out 0x84, ax
        popf
        ret
.lr:    ; live reverse (rosetta_lrev.asm): 15h = the dry input, no send; 17h = the reversed input on the outs
        push es               ; (IN 50 = 80h a side = the dry, IN 99 = FFh; hw 0.24: 7Fh max was "not wet
        mov ax, MENU_SEG      ; enough") + the same send into the FX (REV HALL etc.)
        mov es, ax
        mov al, [es:LO_isendv + 1]
        pop es
        xor ah, ah                ; x the chunk's COMP gain / 256, FFh at most (the chip's volume: no clipping)
        mul word [cs:lr_cg]
        mov al, ah
        mov ah, dl
        or ah, ah
        jz .cg
        mov al, 0xFF
.cg:    mov ah, al                ; L = R = wet
        cmp byte [cs:lr_pp], 0
        je .lb
        cmp byte [cs:lr_side], 0  ; ping-pong: one side a chunk (lr_fill flips it as the chunk comes out)
        jne .rg
        xor al, al
        jmp .lb
.rg:    xor ah, ah
.lb:    mov cx, ax
        cmp byte [cs:lr_kind], 3  ; 0.28 LO-FI: the dry only
        jne .lk
        xor cx, cx
.lk:    mov al, [cs:lr_tone]      ; tone: the wet voice's low-pass target, 2000h dark .. 7FF0h open (reg 6
        xor ah, ah                ; word 1, as the OS writes it at 2345:5746; the template has 7FF0h)
        mov dx, 0x5FF0
        mul dx
        mov si, 99
        div si
        add ax, 0x2000
        and ax, 0xFFF0
        mov si, ax
        mov al, [cs:lr_dry]       ; DRY: the input voice's level, 99 = 80h a side (stock), only with MONITOR on
        mov ah, 0x80
        mul ah
        mov dl, 99
        div dl
        cmp byte [0x7557], 0
        jne .dr
        xor al, al
.dr:    mov ah, al
        mov di, ax
        pushf
        cli
        mov ax, 0x0715
        out 0x80, ax
        mov ax, di
        out 0x82, ax
        xor ax, ax
        out 0x84, ax
        mov ax, 0x0717
        out 0x80, ax
        mov ax, cx
        out 0x82, ax
        mov ax, bx
        out 0x84, ax
        mov ax, 0x0517            ; reg 5 word 1 = the current cutoff / 2: set it there, no glide
        out 0x80, ax
        mov ax, si
        shr ax, 1
        out 0x84, ax
        mov ax, 0x0617
        out 0x80, ax
        mov ax, si
        out 0x84, ax
        popf
        ret

; ax = 16-bit random (xorshift)
rnd:    mov ax, [cs:seed]
        mov dx, ax
        shl dx, 7
        xor ax, dx
        mov dx, ax
        shr dx, 9
        xor ax, dx
        mov dx, ax
        shl dx, 8
        xor ax, dx
        mov [cs:seed], ax
        ret

; cs:si = 2 x 16 chars -> the OS popup buffer, shown for a few seconds (0FE4:0D4E, DS = 0).
; Clobbers ax, bx, si.
popup:  push es
        push di
        push cx
        xor ax, ax
        mov es, ax
        mov di, POPUP
        mov cx, 32
.c:     cs lodsb
        stosb
        loop .c
        mov al, 0xFF
        stosb
        mov bx, POPUP
        call 0x0FE4:0x0D4E
        pop cx
        pop di
        pop es
        ret

ticks:    dw 0
mbox:     db 0                ; command (0 = idle)
mb_t0:    db 0
mb_addr:  dd 0
mb_count: dw 0
mb_t1:    db 0
mb_res:   dw 0
mb_res2:  dw 0
hammer:   dw 0
pfail:    db 0
inited:   db 0
lasttick: db 0
npass:    dw 0
ptick:    db 0
maxgap:   db 0
dacc:     db 0
racc:     db 0
cacc:     db 0
cbusy:    db 0                ; the last pass had a control on
nt:       db 0
par:     times NCC db 0      ; CC 20-31: drift, speed, detune, flt LFO depth, rate, spread, REV x4, (30-31 free)
          db 0
seed:     dw 0xACE1
dnext:    dw 0
lphase:   dw 0
poff:     times NVOICE dw 0   ; per-voice pitch offset (1/256 semitone)
coff:     times NVOICE dw 0   ; per-voice cutoff offset (log units, 0 = off)
dpos:     times NVOICE dw 0   ; drift position (Q15)
dtgt:     times NVOICE dw 0   ; drift target (Q15)
msg_ok:   db "ROSETTA+ READY  SYNTH CC 20-25  "
msg_pf:   db "ROSETTA+ READY  PATCH MISMATCH! "

%include "rosetta_rev.asm"
%include "rosetta_plus.asm"
%include "rosetta_chop.asm"
%include "rosetta_lrev.asm"
%include "rosetta_rvui.asm"
%include "rosetta_knobs.asm"
%include "rosetta_synui.asm"
%include "hi_fx.inc"
%include "lo_syms.inc"
%include "hi_tables.inc"      ; hsin (256 x Q14), dtab (32 x signed detune spread), from mkbaby.py

        align 1024, db 0
kn_blk:   times 1024 db 0     ; the saved knobs: its own floppy block, loaded with the code (rosetta_knobs.asm)
