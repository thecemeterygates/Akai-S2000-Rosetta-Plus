#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  uint16_t r[8];   // AX CX DX BX SP BP SI DI
  uint16_t s[4];   // ES CS SS DS
  uint16_t ip, flags;
  int halted, inhibit_irq;
  uint64_t icount;
} CPU;
extern CPU cpu;

void cpu_init_tables(void);
int cpu_step(void);
void cpu_interrupt(int n);

uint8_t rd8(uint16_t seg, uint16_t off);
uint16_t rd16(uint16_t seg, uint16_t off);
void wr8(uint16_t seg, uint16_t off, uint8_t v);
void wr16(uint16_t seg, uint16_t off, uint16_t v);
uint8_t io_in8(uint16_t port);
uint16_t io_in16(uint16_t port);
void io_out8(uint16_t port, uint8_t v);
void io_out16(uint16_t port, uint16_t v);
void v53_set_xam(int on);
void emu_fault(const char *fmt, ...);

#define PHYS_SIZE (32u<<20)
extern uint8_t *phys;
uint32_t xlate(uint32_t lin);
