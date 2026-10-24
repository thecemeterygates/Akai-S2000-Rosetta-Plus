; Live reverse (0.24): the REV types on the input, SAMPLE page only. Included by rosetta_hi.asm, runs from its tick.
;
; Stock input (2345:3078, mono): the ADC's DMA (ch2) fills an 8 KB ring at 0:90D0, the chip's input DMA (ch3) reads
; the same ring 5 samples behind (hw 0.24) and the chip writes it to sample RAM (voice 0 ring 10000h), where
; voice 15h plays it (the monitor). Here ch3 reads our own 8 KB ring instead (4000:E000, 2048 stereo frames) with
; the chip in stereo input mode: every pass copies the new ADC samples in, L = the input (voice 0 -> 15h, the dry
; monitor), R = the previous chunk of the input backwards (voice 10h -> 17h, the reverse wet: level, FX send, pan
; and tone in mfx_run). Our writes run LR_D frames ahead of ch3, so the monitor is ~9 ms later than stock while
; this runs. The ADC side stays stock. Arming, a take, or leaving the page hands the input back to the OS.
;
; Knobs (lr_bpm .. lr_pp below; FEEDBACK = the MFX FB field):
;   chunk     tempo mode: a 1/16, 1/8, dotted 1/8, 1/4 or dotted 1/4 at lr_bpm; lr_bpm 0 = FREE, LEN ms
;   history   20480 samples at 44.1, 22 or 11 kHz (lr_rl 0 / 1 / 2): the fullest rate that holds what a chunk needs
;             (N written + N x octave read), so long chunks / octave up get darker (the dry never does)
;   octave    -1 / 0 / +1: the reversed chunk at half / normal / double speed (reads step 2^-e history samples a
;             frame, e = log2 rate divider - octave, -1..3: e >= 1 = linear steps with adds only; this CPU is ~40 %
;             busy with live reverse already, a multiply a sample is too much)
;   swell     the CPU fade at each chunk edge (6 ms = anti-click; longer costs CPU: ATTACK / RELEASE instead)
;   attack /  the wet voice's own envelope per chunk: a ramp up from the chunk's start, a ramp down to its end
;   release   (free: the chip does it; fired when ch3 reaches the chunk, ~a main-loop pass late at most)
;   comp      per-chunk leveling on the wet voice's volume: each chunk's peak is taken as it is recorded and the
;             chunk plays back towards one level (up to 4x up, any down), blended by COMP; no sample clipping.
;             Gate (0.25): a chunk quieter than -18 dB gets less boost, down to none at -30 dB and silence below
;   feedback  the history takes L + FB x R: a repeat comes back reversed again
;   ping-pong each chunk on the other side; tone = the wet voice's own low-pass
;   start/end a loop inside the reversed chunk, like a sample's loop points: only START..END % plays, round and
;             round until the next chunk (each pass faded in / out)
LR_HOFF   equ 0x5000              ; input history 4000:5000-DFFF (0.28: 18432 words, was 4000-: the hi code grew; LABBUF / SCANBUF overlap it, they
LR_HEND   equ 0xE000              ; are never used on the SAMPLE page)
LR_CAP    equ LR_HEND - LR_HOFF   ; history bytes (N x the read factor in halves must fit LR_CAP x R)
LR_BOFF   equ 0xE000              ; ch3 ring 4000:E000-FFFF = linear 4E000h
LR_BLIN   equ (HI_SEG << 4) + LR_BOFF
LR_D      equ 512                 ; frames our writes lead ch3 (11.6 ms; hw: passes ~5 ms apart, gaps up to 9.7 ms
                                  ; with feedback on)
LR_FMIN   equ 258                 ; shortest fade (2^24 / it must fit 16 bits)
LR_NMIN   equ 2048
LR_ELVL   equ 0x741A              ; the wet voice's envelope level (its template, 2D95:38C0 + 16h)
LR_ESTEP  equ 0x1388              ; fastest envelope step we use = the OS's own for this voice (hw 0.24: 7FFFh
                                  ; never climbed: the wet stayed silent after a release)
LR_EMIN   equ (LR_ELVL * 256) / LR_ESTEP + 1  ; = the shortest attack / release, frames (~34 ms)
RING      equ 0x90D0              ; the OS's ADC ring (segment 0), 0x2000 bytes
RETF_0FE4 equ 0x522C              ; a `retf` in segment 0FE4 (after 5229 `call 5390`): near-call trampoline

lr_run:
        cmp byte [cs:lr_act], 0
        je .off
        call dmapos               ; ch3 off our ring = the OS restarted its own input (take, page entry)
        cmp bx, LR_BOFF
        jae .own
        mov byte [cs:lr_act], 0
        ret
.own:   call lr_want
        or al, al
        jz lr_stop
        call lr_len
        jmp lr_fill
.off:   call lr_want
        or al, al
        jz .r
        jmp lr_start
.r:     ret

; al = 1: a REV type is on, MFX IN > 0 and not armed
lr_want:
        xor al, al
        cmp byte [0x7581], 0
        jne .r
        push es
        push bx
        mov bx, MENU_SEG
        mov es, bx
        cmp word [es:LO_isendv], 0
        je .n
        mov bl, [es:LO_fxon]
        xor bh, bh
        shl bx, 1
        shl bx, 1
        mov al, [cs:rev_tab + bx]
        mov [cs:lr_kq], al        ; 0.28: 1 reverse, 2 forward (PITCH / SHIMMER), 3 crusher only (LO-FI)
.n:     pop bx
        pop es
.r:     ret

; per pass: what the next chunk wants (lr_chunk takes it at the boundary) + the feedback gain
lr_len:
        push es
        mov ax, MENU_SEG
        mov es, ax
        mov ax, [es:LO_pfb]       ; feedback: FB 0-99 -> 0-198 / 256
        shl ax, 1
        mov [cs:lr_fbg], ax
        mov bl, [es:LO_fxon]
        xor bh, bh
        shl bx, 1
        shl bx, 1
        mov cl, [cs:lr_bpm]
        or cl, cl
        jz .pct
        cmp cl, 41                ; (2646000 / bpm must fit 16 bits)
        jae .t
        mov cl, 41
.t:     xor ch, ch
        mov dx, 2646000 >> 16     ; 44100 x 60: frames a minute
        mov ax, 2646000 & 0xFFFF
        div cx                    ; = a 1/4 note
        mov bl, [cs:lr_div]
        xor bh, bh
        mov bl, [cs:lr_divm + bx]
        mul bx                    ; x sixteenths / 16
        cmp dx, 16
        jb .t2
        mov ax, 0xFFFE
        jmp .got
.t2:    mov cx, 16
        div cx
        jmp .got
.pct:   mov ax, [cs:lr_lenms]     ; FREE: LEN ms x 44.1
        mov cx, 441
        mul cx
        mov cx, 10
        div cx
.got:   pop es
        cmp ax, LR_NMIN
        jae .a
        mov ax, LR_NMIN
.a:     and ax, 0xFFFE
        mov [cs:lr_nq], ax
        ; history rate: N (2 + octave factor in halves) <= 40960 x R, R = 1, 2, 4 (else N is cut)
        mov bx, 4
        mov al, [cs:lr_oct]
        or al, al
        jz .k
        mov bx, 3
        js .k
        mov bx, 6
.k:     mov ax, [cs:lr_nq]
        mul bx
        xor cl, cl
        or dx, dx
        jnz .r2
        cmp ax, LR_CAP
        jbe .rs
.r2:    inc cl
        cmp dx, (2 * LR_CAP) >> 16
        ja .r4
        jb .rs
        cmp ax, (2 * LR_CAP) & 0xFFFF
        jbe .rs
.r4:    inc cl
        cmp dx, (4 * LR_CAP) >> 16
        ja .cut
        jb .rs
        cmp ax, (4 * LR_CAP) & 0xFFFF
        jbe .rs
.cut:   mov dx, (4 * LR_CAP) >> 16
        mov ax, (4 * LR_CAP) & 0xFFFF
        div bx
        and ax, 0xFFFE
        mov [cs:lr_nq], ax
.rs:    mov [cs:lr_rlq], cl
        sub cl, [cs:lr_oct]       ; read step 2^-e: e = log2 R - octave
        mov [cs:lr_eq], cl
        ret

; ax = ch2 byte offset in the ADC ring, bx = ch3 address (low 16 bits); the DMAU channel select is put back
dmapos:
        pushf
        cli
        mov dx, 0xC001
        in al, dx
        mov cl, al
        mov al, 2
        out dx, al
        mov dx, 0xC004
        in ax, dx
        mov si, ax
        mov dx, 0xC001
        mov al, 3
        out dx, al
        mov dx, 0xC004
        in ax, dx
        mov bx, ax
        mov dx, 0xC001
        mov al, cl
        out dx, al
        popf
        mov ax, si
        sub ax, RING
        and ax, 0x1FFE
        ret

lr_start:
        call lr_len
        push es
        mov ax, cs
        mov es, ax
        cld
        xor ax, ax
        mov di, LR_HOFF           ; history + our ring = silence
        mov cx, (0x10000 - LR_HOFF) / 2
        rep stosw
        pop es
        mov word [cs:lr_hw], LR_HOFF
        mov word [cs:lr_j], 0xFFFF    ; the first block starts a chunk (lr_chunk sets the read side)
        mov byte [cs:lr_side], 0
        mov byte [cs:lr_hph], 0
        mov byte [cs:lr_evaon], 0
        mov byte [cs:lr_evron], 0
        mov word [cs:lr_c3f], 0           ; frame counters: ch3 starts on our ring's frame 0, we write LR_D on
        mov word [cs:lr_c3f + 2], 0
        mov word [cs:lr_wf], LR_D
        mov word [cs:lr_wf + 2], 0
        mov word [cs:lr_c3a], LR_BOFF
        mov word [cs:lr_pka], 0
        mov word [cs:lr_cg], 256
        mov word [cs:lr_cgn], 256
        mov word [cs:lr_wb], LR_BOFF + LR_D * 4
        push cs                   ; all voices off, chip out of input mode: the OS's own first step (0FE4:C841)
        push word .c1
        push word RETF_0FE4
        jmp 0x0FE4:0xC841
.c1:    call dmapos
        and ax, 0x1FFC
        mov [cs:lr_last], ax
        ; = 2345:3078 with ch3 on our ring and the chip in stereo
        mov dx, 0xC001
        mov al, 3
        out dx, al
        mov dx, 0xC004
        mov ax, LR_BLIN & 0xFFFF
        out dx, ax
        mov dx, 0xC006
        mov al, LR_BLIN >> 16
        out dx, al
        mov dx, 0xC002
        mov ax, 0x0FFF
        out dx, ax
        mov dx, 0xC00A
        mov al, 0x59
        out dx, al
        mov cl, 0x0C
        call 0x2345:0x2644        ; unmask ch2 + ch3
        call 0x2345:0x2828        ; voice 0 (L in) from its template
        call 0x2345:0x28DE        ; voice 10h (R in)
        mov ax, 0x0158            ; input mode, stereo
        out 0x88, ax
.w:     in al, 0x88
        test al, 0x80
        jnz .w
        cmp byte [0x750C], 0
        jne .bw
        call 0x2345:0x32AF
        call 0x2345:0x32AF
        call 0x2345:0x32AF
.bw:    xor ax, ax                ; 15h = the dry input, centred (if MONITOR is on); 17h's level: mfx_run
        cmp byte [0x7557], 0
        je .m
        mov ax, 0x8080
.m:     push ds
        mov dx, 0x2D95
        mov ds, dx
        mov [0x38B4], ax
        mov word [0x38E0], 0
        pop ds
        mov dx, 0x15
        mov si, 0x3894
        mov cx, 0x1FFD
        call 0x2345:0x40C0
        mov dx, 0x17
        mov si, 0x38C0
        mov cx, 0x1FFD
        call 0x2345:0x40C0
        in al, 0x88
        mov ah, 1
        out 0x88, ax
        mov byte [cs:lr_act], 1
        ret

; back to the stock input (as the OS starts it, minus the ADC, which never stopped)
lr_stop:
        mov byte [cs:lr_act], 0
        push cs
        push word .c1
        push word RETF_0FE4
        jmp 0x0FE4:0xC841
.c1:    call 0x2345:0x3078
        ret

; copy the new ADC samples into our ring: L = input, R = the last chunk backwards. Works in frame pairs and in
; blocks that hit no ring end / chunk end / fade edge, with string moves (a per-sample loop took ~80 % of the CPU
; on hw: main-loop passes 400/s -> 83/s).
lr_fill:
        call dmapos
        and ax, 0x1FFC            ; whole frame pairs
        and bx, 0xFFFC
        mov dx, bx                ; frames ch3 has taken since the last pass
        sub dx, [cs:lr_c3a]
        and dx, 0x1FFF
        shr dx, 1
        shr dx, 1
        add [cs:lr_c3f], dx
        adc word [cs:lr_c3f + 2], 0
        mov [cs:lr_c3a], bx
        sub bx, LR_BOFF           ; ch3 byte offset in our ring
        mov dx, [cs:lr_wb]
        sub dx, LR_BOFF
        sub dx, bx
        and dx, 0x1FFF            ; bytes we lead ch3 by
        cmp dx, LR_D * 2
        jb .sync
        cmp dx, LR_D * 8
        jbe .ok
.sync:  add bx, LR_D * 4          ; a pass came too late (ch3 caught up): lead it again
        and bx, 0x1FF8
        add bx, LR_BOFF
        mov [cs:lr_wb], bx
        mov dx, [cs:lr_c3f]
        mov [cs:lr_wf], dx
        mov dx, [cs:lr_c3f + 2]
        mov [cs:lr_wf + 2], dx
        add word [cs:lr_wf], LR_D
        adc word [cs:lr_wf + 2], 0
.ok:    mov cx, ax
        sub cx, [cs:lr_last]
        and cx, 0x1FFC
        jnz .go
        jmp .ev
.go:    mov si, [cs:lr_last]
        mov [cs:lr_last], ax
        add si, RING
        mov [cs:lr_si], si
        shr cx, 1
        shr cx, 1                 ; new pairs
        push es
        mov ax, cs
        mov es, ax
        cld
.blk:   mov [cs:lr_left], cx
        mov ax, [cs:lr_j]
        cmp ax, [cs:lr_n]
        jb .c00
        call lr_chunk             ; (these use cx: the count comes back from lr_left)
        mov cx, [cs:lr_left]
        jmp .c01
.c00:   mov ax, [cs:lr_js]
        cmp ax, [cs:lr_s]
        jb .c01
        call lr_slice             ; START..END goes round again
        mov cx, [cs:lr_left]
.c01:   call lr_toend             ; dx = frames to the segment end (slice or chunk, whichever comes first)
        mov byte [cs:lr_fd], 2    ; lr_fd 1 = fading in, 2 = fading out
        cmp dx, [cs:lr_f]
        jbe .c2
        sub dx, [cs:lr_f]         ; to where the fade out starts
        mov byte [cs:lr_fd], 0
        mov ax, [cs:lr_js]
        cmp ax, [cs:lr_f]
        jae .c2
        mov byte [cs:lr_fd], 1
        mov bx, [cs:lr_f]         ; fading in: to the fade's end at most
        sub bx, ax
        cmp bx, dx
        jae .c2
        mov dx, bx
.c2:    shr dx, 1
        cmp cx, dx
        jbe .c3
        mov cx, dx
.c3:    mov dx, RING + 0x2000     ; ADC ring end
        sub dx, [cs:lr_si]
        shr dx, 1
        shr dx, 1
        cmp cx, dx
        jbe .c4
        mov cx, dx
.c4:    mov dx, [cs:lr_wb]        ; our ring end
        neg dx
        shr dx, 1
        shr dx, 1
        shr dx, 1
        cmp cx, dx
        jbe .c5
        mov cx, dx
.c5:    mov dx, LR_HEND           ; history write end (44.1 kHz: 2 samples a pair, else at most 1)
        sub dx, [cs:lr_hw]
        shr dx, 1
        cmp byte [cs:lr_rl], 0
        jne .c6
        shr dx, 1
.c6:    cmp cx, dx
        jbe .c9
        mov cx, dx
.c9:    or cx, cx                 ; (never 0; if it were, give up this pass rather than spin)
        jnz .do
        jmp .done
.do:    mov [cs:lr_m], cx
        ; 1. L: the input, every other word of our ring
        mov si, [cs:lr_si]
        mov [cs:lr_si0], si
        mov di, [cs:lr_wb]
        shl cx, 1
.lc:    movsw
        inc di
        inc di
        loop .lc
        cmp si, RING + 0x2000
        jb .ly
        mov si, RING
.ly:    mov [cs:lr_si], si
        ; 2. R: the history backwards (DS = hi, DF = 1; every read wraps at the history start itself)
        cmp byte [cs:lr_kind], 3  ; LO-FI: no wet to read
        jne .r0
        jmp .hs
.r0:    mov di, [cs:lr_wb]
        mov si, [cs:lr_rr]
        mov cx, [cs:lr_m]
        shl cx, 1
        push ds
        mov ax, cs
        mov ds, ax
..@lr_pstd: std                      ; (cld reading forwards: lr_dir patches it, and the wraps below)
        mov al, [cs:lr_e]
        or al, al
        jz .e0
        js .em
        cmp al, 1
        jne .eg
        shr cx, 1                 ; e = 1: each history sample, then halfway to the next (a pair of frames)
        mov bx, [cs:lr_cur]
.e1:    mov [es:di + 2], bx
        lodsw
..@lr_pc1: cmp si, LR_HOFF - 2
        jne .e1a
..@lr_pm1: mov si, LR_HEND - 2
.e1a:   mov dx, ax
        sar ax, 1
        mov bp, bx
        sar bp, 1
        add ax, bp
        mov [es:di + 6], ax
        mov bx, dx
        add di, 8
        loop .e1
        mov [cs:lr_cur], bx
        jmp .rx
.eg:    mov bx, [cs:lr_out]       ; e >= 2: 2^e frames per history sample, linear steps
        mov dx, [cs:lr_dst]
        mov bp, [cs:lr_cnt]
.ei:    mov [es:di + 2], bx
        add di, 4
        add bx, dx
        dec bp
        jnz .ein
        call lr_next
.ein:   loop .ei
        mov [cs:lr_out], bx
        mov [cs:lr_dst], dx
        mov [cs:lr_cnt], bp
        jmp .rx
.e0:    lodsw                     ; e = 0: a history sample a frame
..@lr_pc2: cmp si, LR_HOFF - 2
        jne .e0a
..@lr_pm2: mov si, LR_HEND - 2
.e0a:   mov [es:di + 2], ax
        add di, 4
        loop .e0
        jmp .rx
.em:    lodsw                     ; e = -1 (octave up at 44.1 kHz): two a frame, averaged
..@lr_pc3: cmp si, LR_HOFF - 2
        jne .em1
..@lr_pm3: mov si, LR_HEND - 2
.em1:   sar ax, 1
        mov dx, ax
        lodsw
..@lr_pc4: cmp si, LR_HOFF - 2
        jne .em2
..@lr_pm4: mov si, LR_HEND - 2
.em2:   sar ax, 1
        add ax, dx
        mov [es:di + 2], ax
        add di, 4
        loop .em
.rx:    cld
        pop ds
        mov [cs:lr_rr], si
        ; 3. fades on the right slots just written (a block is all fade-in, all fade-out or none)
        cmp byte [cs:lr_fd], 0
        je .hs
        mov cx, [cs:lr_m]
        shl cx, 1
        mov di, [cs:lr_wb]
        mov ax, [cs:lr_js]        ; gain x 2^16 at the block's first frame: frames in x step fading in, frames
        cmp byte [cs:lr_fd], 1    ; to the end x step fading out
        je .g1
        call lr_toend
        mov ax, dx
.g1:    mul word [cs:lr_ginc]
        mov bx, dx                ; bx = gain / 256, bp = its fraction
        mov bp, ax
.fl:    mov ax, [es:di + 2]
        imul bx
        mov al, ah
        mov ah, dl
        mov [es:di + 2], ax
        add di, 4
        cmp byte [cs:lr_fd], 1
        jne .fo
        add bp, [cs:lr_ginc]
        adc bx, 0
        loop .fl
        jmp .hs
.fo:    sub bp, [cs:lr_ginc]
        sbb bx, 0
        loop .fl
        ; 4. history: no feedback = straight from the ADC ring; feedback = from our ring, L + FB x R
.hs:    call lf_run               ; 0.28: LO-FI on the frames just written (rosetta_plus.asm)
        mov di, [cs:lr_hw]
        mov cx, [cs:lr_m]
        cmp word [cs:lr_fbg], 0
        jne .hfb
        mov si, [cs:lr_si0]
        cmp byte [cs:lr_rl], 0
        jne .hd
        shl cx, 1
        rep movsw
        jmp .hx
.hd:    cmp byte [cs:lr_rl], 1
        jne .hq
.h2:    lodsw                     ; 22 kHz: a pair's average (each halved first: signed; add + rcr is only
        sar ax, 1                 ; right unsigned, lrsim.py caught 100, -50 -> -32743)
        mov dx, ax
        lodsw
        sar ax, 1
        add ax, dx
        stosw
        loop .h2
        jmp .hx
.hq:    lodsw                     ; 11 kHz
        sar ax, 1
        mov dx, ax
        lodsw
        sar ax, 1
        add ax, dx
        call lr_hput
        loop .hq
        jmp .hx
.hfb:   mov si, [cs:lr_wb]
        push ds
        mov ax, cs
        mov ds, ax
        cmp byte [cs:lr_rl], 0
        jne .hf2
        shl cx, 1
.hf1:   lodsw                     ; L + R x FB / 256, saturated
        mov bx, ax
        lodsw
        imul word [cs:lr_fbg]
        mov al, ah
        mov ah, dl
        add ax, bx
        jno .k1
        mov ax, 0x7FFF            ; (mov keeps the add's flags: a negative result = it overflowed upwards)
        js .k1
        mov ax, 0x8000
.k1:    stosw
        loop .hf1
        jmp .hz
.hf2:   lodsw                     ; (L0 + L1) / 2 + (R0 + R1) / 2 x FB / 256: one multiply a pair
        sar ax, 1
        mov bx, ax
        lodsw
        sar ax, 1
        mov bp, ax
        lodsw
        sar ax, 1
        add bx, ax
        lodsw
        sar ax, 1
        add ax, bp
        imul word [cs:lr_fbg]
        mov al, ah
        mov ah, dl
        add ax, bx
        jno .k2
        mov ax, 0x7FFF
        js .k2
        mov ax, 0x8000
.k2:    call lr_hput
        loop .hf2
.hz:    pop ds
.hx:    cmp di, LR_HEND
        jb .hy
        mov di, LR_HOFF
.hy:    xchg di, [cs:lr_hw]       ; COMP: the peak of the samples just written (every 4th)
        mov si, di
        mov cx, [cs:lr_hw]
        sub cx, si
        jbe .pk                   ; (wrapped: skip this block)
        shr cx, 1
        shr cx, 1
        shr cx, 1
        jz .pk
        mov bx, [cs:lr_pka]
.pl:    mov ax, [es:si]
        cwd
        xor ax, dx
        sub ax, dx
        cmp ax, bx
        jbe .pn
        mov bx, ax
.pn:    add si, 8
        loop .pl
        mov [cs:lr_pka], bx
.pk:    ; advance: j += 2m frames, our ring += 8m bytes, the written-frame count
        mov ax, [cs:lr_m]
        shl ax, 1
        add [cs:lr_j], ax
        add [cs:lr_js], ax
        add [cs:lr_wf], ax
        adc word [cs:lr_wf + 2], 0
        shl ax, 1
        shl ax, 1
        add ax, [cs:lr_wb]
        jnz .wb
        mov ax, LR_BOFF
.wb:    mov [cs:lr_wb], ax
        mov cx, [cs:lr_left]
        sub cx, [cs:lr_m]
        jz .done
        jmp .blk
.done:  pop es
.ev:    ; chunk events, when ch3 (= what plays) reaches them
        cmp byte [cs:lr_evaon], 0
        je .e2
        mov ax, [cs:lr_c3f]
        mov dx, [cs:lr_c3f + 2]
        sub ax, [cs:lr_eva]
        sbb dx, [cs:lr_eva + 2]
        js .e2
        call lr_att_fire
.e2:    cmp byte [cs:lr_evron], 0
        je .r
        mov ax, [cs:lr_c3f]
        mov dx, [cs:lr_c3f + 2]
        sub ax, [cs:lr_evr]
        sbb dx, [cs:lr_evr + 2]
        js .r
        mov byte [cs:lr_evron], 0
        mov ax, [cs:lr_rrate]     ; RELEASE: the envelope down to 0 (rate bit 15 = down)
        or ah, 0x80
        mov bx, ax
        xor cx, cx
        call lr_env
.r:     ret

; a chunk starts playing: ping-pong side, its COMP gain, ATTACK (or straight up), RELEASE scheduled
lr_att_fire:
        mov byte [cs:lr_evaon], 0
        xor byte [cs:lr_side], 1
        mov ax, [cs:lr_cgn]
        mov [cs:lr_cg], ax
        mov bx, LR_ESTEP          ; up: at the attack rate, or as fast as we go (never by zeroing reg 3, the
        cmp byte [cs:lr_att], 0   ; level: a 0 there keys the voice off and the wet stayed dead on hw)
        je .go
        mov bx, [cs:lr_arate]
.go:    mov cx, LR_ELVL
        call lr_env
        mov al, [cs:lr_rel]       ; down before the chunk ends: RELEASE, or with ATTACK the shortest one (the
        or al, [cs:lr_att]        ; next attack starts from 0)
        jz .r
        mov ax, [cs:lr_eva]       ; RELEASE starts N - its length after the chunk's start
        mov dx, [cs:lr_eva + 2]
        add ax, [cs:lr_n]
        adc dx, 0
        sub ax, [cs:lr_rlen]
        sbb dx, 0
        mov [cs:lr_evr], ax
        mov [cs:lr_evr + 2], dx
        mov byte [cs:lr_evron], 1
.r:     ret

; the wet voice's envelope: target cx, rate bx (reg 4: word 1 target, word 0 rate, as vstart writes them)
lr_env:
        pushf
        cli
        mov ax, 0x0417
        out 0x80, ax
        mov ax, cx
        out 0x84, ax
        mov ax, bx
        out 0x82, ax
        popf
        ret

; a pair's history sample in ax -> es:di: 22 kHz stores each, 11 kHz every other one (the two averaged)
lr_hput:
        cmp byte [cs:lr_rl], 1
        je .s
        xor byte [cs:lr_hph], 1
        jz .s2
        mov [cs:lr_hpv], ax
        ret
.s2:    sar ax, 1
        push dx
        mov dx, [cs:lr_hpv]
        sar dx, 1
        add ax, dx
        pop dx
.s:     stosw
        ret

; e >= 1 reader (DS = hi, DF = 1): head for the next history sample. bx = the current one (= the old next),
; dx = (next - current) / 2^e a frame, bp = 2^e frames
lr_next:
        mov bx, [cs:lr_nx]
        lodsw
..@lr_pc5: cmp si, LR_HOFF - 2
        jne .a
..@lr_pm5: mov si, LR_HEND - 2
.a:     mov [cs:lr_nx], ax
        sar ax, 1
        mov dx, bx
        sar dx, 1
        sub ax, dx
        push cx
        mov cl, [cs:lr_e]
        dec cl
        sar ax, cl
        pop cx
        mov dx, ax
        mov bp, [cs:lr_ecnt]
        ret

; a new chunk: take the wanted length / rate / step, size the fades, and play the chunk just recorded backwards
; from its newest sample
lr_chunk:
        mov word [cs:lr_j], 0
        mov al, [cs:lr_kq]
        cmp al, [cs:lr_kind]
        je .kd
        mov [cs:lr_kind], al
        call lr_dir
.kd:
        mov al, [cs:lr_rlq]
        mov [cs:lr_rl], al
        mov al, [cs:lr_eq]
        mov [cs:lr_e], al
        mov ax, [cs:lr_nq]
        mov [cs:lr_n], ax
        shr ax, 1                 ; fade = LR_FMIN .. N / 2 by SWELL
        sub ax, LR_FMIN
        mov cl, [cs:lr_sw]
        xor ch, ch
        mul cx
        mov cx, 99
        div cx
        add ax, LR_FMIN
        and ax, 0xFFFE
        mov [cs:lr_f], ax
        mov cx, ax
        mov dx, 0x0100
        xor ax, ax
        div cx                    ; 2^24 / fade = the gain step (x 2^16 / 256)
        mov [cs:lr_ginc], ax
        mov ax, [cs:lr_wf]        ; this chunk's first frame: its events fire when ch3 gets there
        mov [cs:lr_eva], ax
        mov ax, [cs:lr_wf + 2]
        mov [cs:lr_eva + 2], ax
        mov byte [cs:lr_evaon], 1
        mov ax, [cs:lr_n]         ; RELEASE length LR_EMIN .. N / 2, ATTACK LR_EMIN .. what is left
        shr ax, 1
        sub ax, LR_EMIN
        mov cl, [cs:lr_rel]
        xor ch, ch
        mul cx
        mov cx, 99
        div cx
        add ax, LR_EMIN
        mov [cs:lr_rlen], ax
        call .rate
        mov [cs:lr_rrate], ax
        mov ax, [cs:lr_n]
        sub ax, [cs:lr_rlen]
        sub ax, LR_EMIN
        mov cl, [cs:lr_att]
        xor ch, ch
        mul cx
        mov cx, 99
        div cx
        add ax, LR_EMIN
        call .rate
        mov [cs:lr_arate], ax
        mov ax, [cs:lr_pka]       ; COMP: towards a peak of 4000h (-6 dB), 4x up at most, blended by COMP
        mov word [cs:lr_pka], 0
        cmp ax, 0x1000
        jae .c1
        shr ax, 1                 ; 0.25 gate: under 1000h (-18 dB) the gain goes down with the peak (4x at
        shr ax, 1                 ; 1000h, 1x at 400h, 0 at 0): hiss between notes is cut, not pumped up 4x
        jmp .c2
.c1:    mov cx, ax
        mov dx, 0x0040
        xor ax, ax
        div cx                    ; 4000h x 256 / peak
.c2:    sub ax, 256
        mov cl, [cs:lr_comp]
        xor ch, ch
        imul cx
        mov cx, 99
        idiv cx
        add ax, 256
        mov [cs:lr_cgn], ax
        mov ax, [cs:lr_hw]
        cmp byte [cs:lr_rl], 0
        jne .h
        test ax, 2                ; 44.1 kHz writes pairs: keep hw on one
        jz .h
        add ax, 2
        cmp ax, LR_HEND
        jb .a0
        mov ax, LR_HOFF
.a0:    mov [cs:lr_hw], ax
.h:     call lr_back              ; the newest sample
        mov [cs:lr_nw], ax
        mov al, [cs:lr_en]        ; START / END: the slice = (END + 1 - START) % of N, at least 4 fades long
        sub al, [cs:lr_st]
        jnc .s1
        xor al, al
.s1:    inc al
        xor ah, ah
        mul word [cs:lr_n]
        mov cx, 100
        div cx
        mov cx, [cs:lr_f]
        shl cx, 1
        shl cx, 1
        cmp ax, cx
        jae .s2
        mov ax, cx
.s2:    and ax, 0xFFFE
        mov [cs:lr_s], ax
        mov al, [cs:lr_st]        ; START, frames into the reversed chunk -> history bytes back from the newest
        xor ah, ah
        mul word [cs:lr_n]
        mov cx, 100
        div cx
        and ax, 0xFFFE
        mov cl, [cs:lr_e]
        or cl, cl
        js .s3
        shr ax, cl                ; 2^-e history samples a frame
        jmp .s4
.s3:    shl ax, 1                 ; e = -1: two a frame
.s4:    shl ax, 1
        mov [cs:lr_soff], ax
        mov ax, [cs:lr_n]         ; 0.28: forwards, the slice starts this far back (history bytes per chunk)
        call lr_frb
        mov [cs:lr_span], ax
        jmp lr_slice
.rate:  mov cx, ax                ; ax = frames -> the envelope rate to go 0 <-> LR_ELVL in them (8.8 a sample),
        mov dx, LR_ELVL >> 8      ; LR_ESTEP at most
        mov ax, (LR_ELVL & 0xFF) << 8
        div cx
        cmp ax, LR_ESTEP
        jbe .rt
        mov ax, LR_ESTEP
.rt:    ret

; the next pass of the slice: from START (lr_soff before the chunk's newest sample), reader set up afresh
lr_slice:
        mov word [cs:lr_js], 0
        mov dx, [cs:lr_soff]
        cmp byte [cs:lr_kind], 2
        jne .bk
        mov dx, [cs:lr_span]      ; forwards: START % in from the oldest sample a chunk reads
        sub dx, [cs:lr_soff]
        sub dx, 2
        jnc .bk
        xor dx, dx
.bk:    mov ax, [cs:lr_nw]
        sub ax, dx
        jc .w
        cmp ax, LR_HOFF
        jae .k
.w:     add ax, LR_HEND - LR_HOFF
.k:     mov [cs:lr_rr], ax
        cmp byte [cs:lr_e], 1
        jl .r
        jg .g
        mov bx, ax                ; e = 1: it is the current sample
        mov bx, [cs:bx]
        mov [cs:lr_cur], bx
        call lr_adv
        mov [cs:lr_rr], ax
        ret
.g:     mov bx, ax                ; e >= 2: it is the first 'next'; the reader starts on it at once
        mov bx, [cs:bx]
        mov [cs:lr_nx], bx
        mov [cs:lr_out], bx
        mov word [cs:lr_dst], 0
        mov word [cs:lr_cnt], 1
        call lr_adv
        mov [cs:lr_rr], ax
        mov cl, [cs:lr_e]
        mov ax, 1
        shl ax, cl
        mov [cs:lr_ecnt], ax
.r:     ret

lr_back:                      ; ax = the history sample before ax (wraps)
        sub ax, 2
        cmp ax, LR_HOFF
        jae .r
        mov ax, LR_HEND - 2
.r:     ret

; 0.28: ax = the next history sample after ax in the reading direction (wraps)
lr_adv: cmp byte [cs:lr_kind], 2
        jne lr_back
        add ax, 2
        cmp ax, LR_HEND
        jb .r
        mov ax, LR_HOFF
.r:     ret

; ax = frames -> history bytes they read (2^-e samples a frame)
lr_frb: mov cl, [cs:lr_e]
        or cl, cl
        js .m
        shr ax, cl
        jmp .s
.m:     shl ax, 1
.s:     shl ax, 1
        ret

; the readers' direction for lr_kind (2 = forwards): the std and the five wrap tests are patched in place
lr_dir: push si
        push bx
        push di
        mov al, 0xFD              ; std
        mov bx, LR_HOFF - 2       ; backwards: wrap below the start to the last sample
        mov dx, LR_HEND - 2
        cmp byte [cs:lr_kind], 2
        jne .p
        dec ax                    ; cld
        mov bx, LR_HEND           ; forwards: past the end to the first
        mov dx, LR_HOFF
.p:     mov [cs:..@lr_pstd], al
        mov si, lr_ptab
.l:     mov di, [cs:si]
        or di, di
        jz .x
        mov [cs:di + 2], bx       ; cmp si, imm16 (81 FE iw)
        mov di, [cs:si + 2]
        mov [cs:di + 1], dx       ; mov si, imm16 (BE iw)
        add si, 4
        jmp .l
.x:     pop di
        pop bx
        pop si
        ret
lr_ptab:  dw ..@lr_pc1, ..@lr_pm1, ..@lr_pc2, ..@lr_pm2, ..@lr_pc3, ..@lr_pm3, ..@lr_pc4, ..@lr_pm4
          dw ..@lr_pc5, ..@lr_pm5, 0

; dx = frames to the end of what plays now: the slice or the chunk, whichever ends first
lr_toend:
        push ax
        mov dx, [cs:lr_s]
        sub dx, [cs:lr_js]
        mov ax, [cs:lr_n]
        sub ax, [cs:lr_j]
        cmp dx, ax
        jbe .k
        mov dx, ax
.k:     pop ax
        ret

; knobs (the MFX page / lab set them)
lr_bpm:   db 92               ; tempo (boot: the user's 92); 0 = FREE: LEN ms
lr_lenms: dw 390              ; FREE length, ms (50-900)
lr_div:   db 3                ; (boot 1/4) lr_divm index: 1/16, 1/8, dotted 1/8, 1/4, dotted 1/4
lr_sw:    db 0                ; swell 0-99
lr_tone:  db 99               ; 0 dark - 99 open
lr_oct:   db 1                ; -1 / 0 / +1 (boot +1)
lr_pp:    db 0                ; ping-pong
lr_att:   db 0                ; attack 0-99
lr_rel:   db 0                ; release 0-99
lr_comp:  db 0                ; comp 0-99
lr_st:    db 3                ; (boot 3) start 0-99 (% into the reversed chunk)
lr_dry:   db 99               ; the dry input's level 0-99 (99 = stock)
lr_en:    db 75               ; (boot 75) end 0-99 (last %)
lf_bits:  db 16               ; 0.28 LO-FI: bits 4-16 (16 = clean)
lf_sh:    db 1                ; ... sample-and-hold: 1 frame in 1..16 kept (1 = clean)
ck_on:    db 0                ; ... MIDI clock sync (rosetta_plus.asm)
ck_lfo:   db 0                ; ... and the FX LFOs locked to it
lr_divm:  db 4, 8, 12, 16, 24 ; in sixteenths

lr_act:   db 0
lr_kq:    db 1                ; 0.28: the FX type's kind (rev_tab byte 0), taken at the next chunk ...
lr_kind:  db 1                ; ... in use (1 reverse: the readers as assembled)
lr_span:  dw 0
lr_rl:    db 0                ; history rate in use: 44.1 kHz >> lr_rl
lr_rlq:   db 0                ; ... wanted (taken at the next chunk), likewise lr_e / lr_n
lr_e:     db 0                ; read step 2^-e
lr_eq:    db 0
lr_fd:    db 0
lr_hph:   db 0                ; 11 kHz: a pair is pending in lr_hpv
lr_side:  db 0                ; ping-pong side
lr_evaon: db 0                ; a chunk-start event is pending (lr_eva)
lr_evron: db 0                ; a release is pending (lr_evr)
lr_n:     dw 8192             ; chunk, frames (even)
lr_nq:    dw 8192
lr_f:     dw LR_FMIN          ; fade, frames
lr_ginc:  dw 0
lr_fbg:   dw 0                ; feedback gain / 256 (MFX FB x 2)
lr_last:  dw 0                ; ADC ring byte offset copied up to
lr_si:    dw 0
lr_si0:   dw 0                ; this block's first ADC sample
lr_left:  dw 0
lr_m:     dw 0
lr_cur:   dw 0                ; e = 1 reader
lr_out:   dw 0                ; e >= 2 reader
lr_dst:   dw 0
lr_cnt:   dw 1
lr_ecnt:  dw 2
lr_nx:    dw 0
lr_hpv:   dw 0
lr_hw:    dw LR_HOFF          ; history write
lr_rr:    dw LR_HEND - 2      ; history read (backwards)
lr_wb:    dw LR_BOFF          ; our ring write
lr_j:     dw 0                ; frame in the chunk
lr_js:    dw 0                ; frame in the slice
lr_s:     dw 8192             ; slice, frames
lr_soff:  dw 0                ; START, history bytes back from the newest
lr_nw:    dw LR_HEND - 2      ; the chunk's newest history sample
lr_c3a:   dw 0                ; ch3's last address
lr_c3f:   dd 0                ; frames ch3 has taken
lr_wf:    dd 0                ; frames we have written (frame f plays when lr_c3f reaches it)
lr_eva:   dd 0
lr_evr:   dd 0
lr_rlen:  dw 0
lr_rrate: dw 0
lr_arate: dw 0
lr_pka:   dw 0                ; peak of what is being recorded
lr_cg:    dw 256              ; COMP gain / 256 of the chunk playing
lr_cgn:   dw 256              ; ... of the next one
