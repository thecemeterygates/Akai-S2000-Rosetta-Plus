// Unit-test harness for the Rosetta hi / lo code: the s2kemu CPU core, flat 1 MB, stubbed OS calls, a simulated
// ADC (ch2) + chip input DMA (ch3), port log. Commands on stdin (one per line):
//   load FILE LIN          load a binary at linear LIN (hex)
//   poke LIN HEX..         bytes      pokew LIN HEX..  words
//   peek LIN N             print bytes (hex)          peekw LIN  print one word
//   call SEG OFF           near-call SEG:OFF (stub at SEG:FFF0 = call OFF / hlt), DS = ES = 0
//   retf SEG OFF / ret SEG OFF   plant a retf / ret (OS stubs)
//   sig KIND FREQ AMP      ADC test signal: sine (FREQ Hz) | ramp
//   adv FRAMES             the ADC writes FRAMES samples at ch2, ch2 += 2 x FRAMES, ch3 += 4 x FRAMES; the
//                          frames ch3 passes are appended to the output capture (L R words)
//   tick N                 [73DA] += N
//   cap FILE               write the capture (int16 L, R pairs)
//   portlog FILE           start logging port writes (port value)
#include "emu.h"
#include <math.h>
#include <stdarg.h>
uint8_t *phys;
static uint16_t dma_addr[4], dma_sel;
static FILE *plog;
static int sigk; static double sigf=440, siga=8000, sigph;
static int16_t *capb; static size_t capn, capcap;
uint32_t xlate(uint32_t l){ return l & 0xFFFFF; }
uint8_t rd8(uint16_t s, uint16_t o){ return phys[(((uint32_t)s<<4)+o)&0xFFFFF]; }
uint16_t rd16(uint16_t s, uint16_t o){ return rd8(s,o) | rd8(s,(uint16_t)(o+1))<<8; }
void wr8(uint16_t s, uint16_t o, uint8_t v){ phys[(((uint32_t)s<<4)+o)&0xFFFFF]=v; }
void wr16(uint16_t s, uint16_t o, uint16_t v){ wr8(s,o,v); wr8(s,(uint16_t)(o+1),v>>8); }
void v53_set_xam(int on){ (void)on; }
void emu_fault(const char *f, ...){ va_list a; va_start(a,f); vfprintf(stderr,f,a); va_end(a); exit(3); }
uint8_t io_in8(uint16_t p){ if(p==0xC001) return dma_sel; if(p==0x88) return 0; if(p==0x62) return 0; return 0; }
uint16_t io_in16(uint16_t p){ if(p==0xC004) return dma_addr[dma_sel&3]; return io_in8(p); }
void io_out8(uint16_t p, uint8_t v){ if(p==0xC001) dma_sel=v&3; if(plog) fprintf(plog,"%04x %02x\n",p,v); }
void io_out16(uint16_t p, uint16_t v){ if(p==0xC004){ dma_addr[dma_sel&3]=v; } if(p==0xC001) dma_sel=v&3; if(plog) fprintf(plog,"%04x %04x\n",p,v); }
static void run_call(uint16_t seg, uint16_t off){
  uint16_t st= seg==0x4000 ? (getenv("STUB")?(uint16_t)strtol(getenv("STUB"),0,16):0x4F00) : 0x15F0; wr8(seg,st,0xE8); wr16(seg,st+1,(uint16_t)(off-(st+3))); wr8(seg,st+3,0xF4);
  cpu.s[1]=seg; cpu.ip=st; cpu.s[3]=0; cpu.s[0]=0; cpu.s[2]=0; cpu.r[4]=0x7F00; cpu.halted=0; cpu.flags=0x0202;
  uint64_t n=0; while(!cpu.halted){ cpu_step(); if(++n>200000000ull){ fprintf(stderr,"runaway at %04x:%04x\n",cpu.s[1],cpu.ip); exit(4);} }
}
#define RING 0x90D0
int main(void){
  phys=calloc(1,PHYS_SIZE); cpu_init_tables();
  dma_addr[2]=RING; dma_addr[3]=0xE000;
  char line[4096], s[512]; unsigned a,b;
  while(fgets(line,sizeof line,stdin)){
    char cmd[32]={0}; if(sscanf(line,"%31s",cmd)!=1) continue;
    char *p=line+strlen(cmd);
    if(!strcmp(cmd,"load")){ sscanf(p,"%511s %x",s,&a); FILE*f=fopen(s,"rb"); if(!f){perror(s);return 1;} size_t k=fread(phys+a,1,0x100000-a,f); fclose(f); fprintf(stderr,"loaded %zu at %05x\n",k,a); }
    else if(!strcmp(cmd,"poke")||!strcmp(cmd,"pokew")){ int k; sscanf(p,"%x%n",&a,&k); p+=k; unsigned v; while(sscanf(p,"%x%n",&v,&k)==1){ p+=k; phys[a++]=v; if(cmd[4]=='w') phys[a++]=v>>8; } }
    else if(!strcmp(cmd,"peek")){ sscanf(p,"%x %u",&a,&b); printf("peek %05x:",a); for(unsigned k=0;k<b;k++) printf(" %02x",phys[a+k]); printf("\n"); fflush(stdout); }
    else if(!strcmp(cmd,"peekw")){ sscanf(p,"%x",&a); printf("%u\n",phys[a]|phys[a+1]<<8); fflush(stdout); }
    else if(!strcmp(cmd,"call")){ sscanf(p,"%x %x",&a,&b); run_call(a,b); }
    else if(!strcmp(cmd,"retf")){ sscanf(p,"%x %x",&a,&b); wr8(a,b,0xCB); }
    else if(!strcmp(cmd,"ret")){ sscanf(p,"%x %x",&a,&b); wr8(a,b,0xC3); }
    else if(!strcmp(cmd,"sig")){ char k[16]; double f2=440,a2=8000; sscanf(p,"%15s %lf %lf",k,&f2,&a2); sigk=!strcmp(k,"ramp"); sigf=f2; siga=a2; }
    else if(!strcmp(cmd,"tick")){ sscanf(p,"%u",&a); uint16_t t=phys[0x73DA]|phys[0x73DB]<<8; t+=a; phys[0x73DA]=t; phys[0x73DB]=t>>8; }
    else if(!strcmp(cmd,"adv")){
      sscanf(p,"%u",&a);
      for(unsigned k=0;k<a;k++){
        int16_t v;
        if(sigk){ v=(int16_t)(((long)(sigph))&0x7FFF); sigph+=sigf; }
        else { v=(int16_t)lrint(siga*sin(sigph)); sigph+=2*M_PI*sigf/44100.0; }
        uint16_t o=dma_addr[2]; phys[o]=v; phys[o+1]=(uint16_t)v>>8;
        o+=2; if(o>=RING+0x2000) o=RING; dma_addr[2]=o;
        uint32_t c=0x40000+dma_addr[3];
        if(capn+2>capcap){ capcap=capcap?capcap*2:65536; capb=realloc(capb,capcap*2); }
        capb[capn++]=(int16_t)(phys[c]|phys[c+1]<<8); capb[capn++]=(int16_t)(phys[c+2]|phys[c+3]<<8);
        uint16_t d=dma_addr[3]+4; if(d==0) d=0xE000; dma_addr[3]=d;
      }
    }
    else if(!strcmp(cmd,"cap")){ sscanf(p,"%511s",s); FILE*f=fopen(s,"wb"); fwrite(capb,2,capn,f); fclose(f); capn=0; }
    else if(!strcmp(cmd,"setr")){ sscanf(p,"%u %x",&a,&b); cpu.r[a&7]=b; }
    else if(!strcmp(cmd,"plmark")){ if(plog) fprintf(plog,"M\n"); }
    else if(!strcmp(cmd,"getr")){ printf("r %04x %04x %04x %04x\n",cpu.r[0],cpu.r[1],cpu.r[2],cpu.r[3]); fflush(stdout); }
    else if(!strcmp(cmd,"portlog")){ sscanf(p,"%511s",s); if(plog) fclose(plog); plog=fopen(s,"w"); }
    else fprintf(stderr,"? %s",line);
  }
  if(plog) fclose(plog);
  return 0;
}
