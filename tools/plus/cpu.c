// 80186/V33-class real-mode CPU core for the Akai S2000 (NEC V53) emulator
#include "emu.h"

static uint32_t insn_start_cs, insn_start_ip;
CPU cpu;
int calltrace; FILE *ctf;
static void ct(uint16_t cs,uint16_t ip){ if(calltrace) fprintf(ctf?ctf:stderr,"%05x <- %05x\n",(unsigned)(((uint32_t)cs<<4)+ip)&0xfffff,(unsigned)((insn_start_cs<<4)+insn_start_ip)&0xfffff); }

#define AX cpu.r[0]
#define CX cpu.r[1]
#define DX cpu.r[2]
#define BX cpu.r[3]
#define SP cpu.r[4]
#define BP cpu.r[5]
#define SI cpu.r[6]
#define DI cpu.r[7]
#define ES cpu.s[0]
#define CS cpu.s[1]
#define SS cpu.s[2]
#define DS cpu.s[3]
#define IP cpu.ip

#define FC 0x0001
#define FP 0x0004
#define FA 0x0010
#define FZ 0x0040
#define FS 0x0080
#define FT 0x0100
#define FI 0x0200
#define FD 0x0400
#define FO 0x0800

static int segovr; // -1 none
static int rep;    // 0 none, 1 repz, 2 repnz
static uint16_t ea_off; static int ea_seg; static int modrm_mod, modrm_reg, modrm_rm;

static inline uint8_t *r8p(int n){ uint8_t *b=(uint8_t*)&cpu.r[n&3]; return b+((n>>2)&1); }
static inline void setf(uint16_t f,int c){ if(c) cpu.flags|=f; else cpu.flags&=~f; }
static inline int getf(uint16_t f){ return (cpu.flags&f)!=0; }

static inline uint8_t fetch8(void){ uint8_t v=rd8(CS,IP); IP++; return v; }
static inline uint16_t fetch16(void){ uint16_t v=fetch8(); v|=fetch8()<<8; return v; }

static const uint8_t parity_tab_init=0; static uint8_t ptab[256];
void cpu_init_tables(void){ for(int i=0;i<256;i++){int c=0;for(int b=0;b<8;b++)c+=(i>>b)&1; ptab[i]=!(c&1);} }

static void szp8(uint8_t v){ setf(FZ,v==0); setf(FS,v&0x80); setf(FP,ptab[v]); }
static void szp16(uint16_t v){ setf(FZ,v==0); setf(FS,v&0x8000); setf(FP,ptab[v&0xff]); }

static void decode_modrm(void){
  uint8_t m=fetch8(); modrm_mod=m>>6; modrm_reg=(m>>3)&7; modrm_rm=m&7;
  if(modrm_mod==3) return;
  uint16_t off=0; int seg=3;
  switch(modrm_rm){
    case 0: off=BX+SI; break; case 1: off=BX+DI; break;
    case 2: off=BP+SI; seg=2; break; case 3: off=BP+DI; seg=2; break;
    case 4: off=SI; break; case 5: off=DI; break;
    case 6: if(modrm_mod==0){ off=fetch16(); } else { off=BP; seg=2; } break;
    case 7: off=BX; break;
  }
  if(modrm_mod==1) off+=(int8_t)fetch8(); else if(modrm_mod==2) off+=fetch16();
  ea_off=off; ea_seg= segovr>=0? segovr: seg;
}
static uint8_t rm8(void){ return modrm_mod==3? *r8p(modrm_rm): rd8(cpu.s[ea_seg],ea_off); }
static uint16_t rm16(void){ return modrm_mod==3? cpu.r[modrm_rm]: rd16(cpu.s[ea_seg],ea_off); }
static void wrm8(uint8_t v){ if(modrm_mod==3) *r8p(modrm_rm)=v; else wr8(cpu.s[ea_seg],ea_off,v); }
static void wrm16(uint16_t v){ if(modrm_mod==3) cpu.r[modrm_rm]=v; else wr16(cpu.s[ea_seg],ea_off,v); }

static void push(uint16_t v){ SP-=2; wr16(SS,SP,v); }
static uint16_t pop(void){ uint16_t v=rd16(SS,SP); SP+=2; return v; }

// ALU
static uint32_t alu(int op,uint32_t a,uint32_t b,int w){
  uint32_t mask=w?0xffff:0xff, sign=w?0x8000:0x80, r=0;
  switch(op){
    case 0: r=a+b; setf(FC,r>mask); setf(FO,((a^r)&(b^r)&sign)); setf(FA,(a^b^r)&0x10); break; //add
    case 1: r=a|b; cpu.flags&=~(FC|FO|FA); break;
    case 2: { int c=getf(FC); r=a+b+c; setf(FC,r>mask); setf(FO,((a^r)&(b^r)&sign)); setf(FA,(a^b^r)&0x10);} break; //adc
    case 3: { int c=getf(FC); r=a-b-c; setf(FC,(uint32_t)b+c>a); setf(FO,((a^b)&(a^r)&sign)); setf(FA,(a^b^r)&0x10);} break; //sbb
    case 4: r=a&b; cpu.flags&=~(FC|FO|FA); break;
    case 5: case 7: r=a-b; setf(FC,b>a); setf(FO,((a^b)&(a^r)&sign)); setf(FA,(a^b^r)&0x10); break;
    case 6: r=a^b; cpu.flags&=~(FC|FO|FA); break;
  }
  r&=mask; if(w) szp16(r); else szp8(r);
  return r;
}
static uint32_t inc_dec(uint32_t a,int dec,int w){
  uint32_t mask=w?0xffff:0xff, sign=w?0x8000:0x80; uint32_t r=(dec? a-1: a+1)&mask;
  if(dec){ setf(FO,a==sign); } else setf(FO,r==sign);
  setf(FA,((a^r)&0x10)); if(w) szp16(r); else szp8(r); return r;
}
static uint32_t shift(int op,uint32_t v,int cnt,int w){
  uint32_t mask=w?0xffff:0xff, sign=w?0x8000:0x80; int bits=w?16:8;
  cnt&=0x1f; if(!cnt) return v;
  for(int i=0;i<cnt;i++){
    uint32_t c;
    switch(op){
      case 0: c=(v&sign)!=0; v=((v<<1)|c)&mask; setf(FC,c); break; //rol
      case 1: c=v&1; v=(v>>1)|(c?sign:0); setf(FC,c); break; //ror
      case 2: c=(v&sign)!=0; v=((v<<1)|getf(FC))&mask; setf(FC,c); break; //rcl
      case 3: c=v&1; v=(v>>1)|(getf(FC)?sign:0); setf(FC,c); break; //rcr
      case 4: case 6: c=(v&sign)!=0; v=(v<<1)&mask; setf(FC,c); break; //shl
      case 5: c=v&1; v>>=1; setf(FC,c); break; //shr
      case 7: c=v&1; v=(v>>1)|(v&sign); setf(FC,c); break; //sar
    }
  }
  switch(op){
    case 0: case 2: setf(FO,((v&sign)!=0)^getf(FC)); break;
    case 1: case 3: setf(FO,((v^(v<<1))&sign)!=0); break;
    case 4: case 6: setf(FO,((v&sign)!=0)^getf(FC)); if(w)szp16(v); else szp8(v); break;
    case 5: setf(FO,cnt==1? 0:0); if(w)szp16(v); else szp8(v); break;
    case 7: setf(FO,0); if(w)szp16(v); else szp8(v); break;
  }
  (void)bits; return v;
}

void cpu_interrupt(int n){
  push(cpu.flags); push(CS); push(IP);
  cpu.flags&=~(FI|FT);
  IP=rd16(0,n*4); CS=rd16(0,n*4+2);
}

static int cond(int c){
  switch(c){
    case 0: return getf(FO); case 1: return !getf(FO);
    case 2: return getf(FC); case 3: return !getf(FC);
    case 4: return getf(FZ); case 5: return !getf(FZ);
    case 6: return getf(FC)||getf(FZ); case 7: return !(getf(FC)||getf(FZ));
    case 8: return getf(FS); case 9: return !getf(FS);
    case 10: return getf(FP); case 11: return !getf(FP);
    case 12: return getf(FS)!=getf(FO); case 13: return getf(FS)==getf(FO);
    case 14: return getf(FZ)||(getf(FS)!=getf(FO)); case 15: return !getf(FZ)&&(getf(FS)==getf(FO));
  }
  return 0;
}

static void divide_error(void){ IP=insn_start_ip; CS=insn_start_cs; cpu_interrupt(0); }

static void string_op(uint8_t op){
  int w=op&1; int d=getf(FD)? -1: 1; int sseg= segovr>=0? segovr: 3;
  for(;;){
    if(rep && CX==0) break;
    switch(op){
      case 0xa4: wr8(ES,DI,rd8(cpu.s[sseg],SI)); SI+=d; DI+=d; break;
      case 0xa5: wr16(ES,DI,rd16(cpu.s[sseg],SI)); SI+=2*d; DI+=2*d; break;
      case 0xa6: alu(7,rd8(cpu.s[sseg],SI),rd8(ES,DI),0); SI+=d; DI+=d; break;
      case 0xa7: alu(7,rd16(cpu.s[sseg],SI),rd16(ES,DI),1); SI+=2*d; DI+=2*d; break;
      case 0xaa: wr8(ES,DI,AX&0xff); DI+=d; break;
      case 0xab: wr16(ES,DI,AX); DI+=2*d; break;
      case 0xac: *r8p(0)=rd8(cpu.s[sseg],SI); SI+=d; break;
      case 0xad: AX=rd16(cpu.s[sseg],SI); SI+=2*d; break;
      case 0xae: alu(7,AX&0xff,rd8(ES,DI),0); DI+=d; break;
      case 0xaf: alu(7,AX,rd16(ES,DI),1); DI+=2*d; break;
      case 0x6c: wr8(ES,DI,io_in8(DX)); DI+=d; break;
      case 0x6d: wr16(ES,DI,io_in16(DX)); DI+=2*d; break;
      case 0x6e: io_out8(DX,rd8(cpu.s[sseg],SI)); SI+=d; break;
      case 0x6f: io_out16(DX,rd16(cpu.s[sseg],SI)); SI+=2*d; break;
    }
    (void)w;
    if(!rep) break;
    CX--;
    if((op==0xa6||op==0xa7||op==0xae||op==0xaf)){
      if(rep==1 && !getf(FZ)) break;
      if(rep==2 && getf(FZ)) break;
    }
  }
}

int cpu_step(void){
  segovr=-1; rep=0;
  insn_start_cs=CS; insn_start_ip=IP;
  uint8_t op;
  for(;;){
    op=fetch8();
    if(op==0x26){segovr=0;continue;} if(op==0x2e){segovr=1;continue;}
    if(op==0x36){segovr=2;continue;} if(op==0x3e){segovr=3;continue;}
    if(op==0xf3){rep=1;continue;} if(op==0xf2){rep=2;continue;}
    if(op==0xf0){continue;} // lock
    break;
  }
  cpu.icount++;
  if(op<0x40 && (op&7)<6){ // ALU block
    int aop=op>>3, form=op&7; uint32_t r;
    switch(form){
      case 0: decode_modrm(); r=alu(aop,rm8(),*r8p(modrm_reg),0); if(aop!=7) wrm8(r); break;
      case 1: decode_modrm(); r=alu(aop,rm16(),cpu.r[modrm_reg],1); if(aop!=7) wrm16(r); break;
      case 2: decode_modrm(); r=alu(aop,*r8p(modrm_reg),rm8(),0); if(aop!=7) *r8p(modrm_reg)=r; break;
      case 3: decode_modrm(); r=alu(aop,cpu.r[modrm_reg],rm16(),1); if(aop!=7) cpu.r[modrm_reg]=r; break;
      case 4: r=alu(aop,AX&0xff,fetch8(),0); if(aop!=7) *r8p(0)=r; break;
      case 5: r=alu(aop,AX,fetch16(),1); if(aop!=7) AX=r; break;
    }
    return 0;
  }
  switch(op){
    case 0x06: push(ES); break; case 0x07: ES=pop(); break;
    case 0x0e: push(CS); break;
    case 0x16: push(SS); break; case 0x17: SS=pop(); break;
    case 0x1e: push(DS); break; case 0x1f: DS=pop(); break;
    case 0x0f: { // NEC extended
      uint8_t o2=fetch8();
      if(o2==0xe0){ uint8_t v=fetch8(); v53_set_xam(1); IP=rd16(0,v*4); CS=rd16(0,v*4+2); break; }
      if(o2==0xf0){ uint8_t v=fetch8(); v53_set_xam(0); IP=rd16(0,v*4); CS=rd16(0,v*4+2); break; }
      if(o2>=0x10 && o2<=0x1f){ // TEST1/CLR1/SET1/NOT1
        decode_modrm(); int w=o2&1; int bit;
        if(o2&8) bit=fetch8(); else bit=CX&0xff;
        bit&= w?15:7; uint16_t v= w? rm16(): rm8(); uint16_t m=1<<bit;
        switch((o2>>1)&3){
          case 0: setf(FZ,!(v&m)); break; //test1
          case 1: v&=~m; if(w)wrm16(v); else wrm8(v); break; //clr1
          case 2: v|=m; if(w)wrm16(v); else wrm8(v); break; //set1
          case 3: v^=m; if(w)wrm16(v); else wrm8(v); break; //not1
        }
        break;
      }
      if(o2==0x28||o2==0x2a){ // ROL4/ROR4 r/m8
        decode_modrm(); uint8_t v=rm8(); uint8_t al=AX&0xff;
        if(o2==0x28){ uint8_t nv=(v<<4)|(al&0xf); *r8p(0)=(al&0xf0)|(v>>4); wrm8(nv);}
        else { uint8_t nv=(al<<4)|(v>>4); *r8p(0)=(al&0xf0)|(v&0xf); wrm8(nv);}
        break;
      }
      emu_fault("unimplemented 0F %02x at %04x:%04x",o2,insn_start_cs,insn_start_ip); return -1;
    }
    case 0x27: { uint8_t al=AX&0xff; int c=getf(FC); if((al&0xf)>9||getf(FA)){al+=6;setf(FA,1);} if(al>0x9f||c||(AX&0xff)>0x99){al+=0x60;setf(FC,1);} *r8p(0)=al; szp8(al);} break; //daa approx
    case 0x2f: { uint8_t al=AX&0xff; if((al&0xf)>9||getf(FA)){al-=6;setf(FA,1);} if((AX&0xff)>0x99||getf(FC)){al-=0x60;setf(FC,1);} *r8p(0)=al; szp8(al);} break;
    case 0x37: if((AX&0xf)>9||getf(FA)){ AX+=0x106; setf(FA,1); setf(FC,1);} else {setf(FA,0);setf(FC,0);} AX&=0xff0f; break;
    case 0x3f: if((AX&0xf)>9||getf(FA)){ AX-=6; *r8p(4)-=1; setf(FA,1); setf(FC,1);} else {setf(FA,0);setf(FC,0);} AX&=0xff0f; break;
    case 0x40 ... 0x47: cpu.r[op&7]=inc_dec(cpu.r[op&7],0,1); break;
    case 0x48 ... 0x4f: cpu.r[op&7]=inc_dec(cpu.r[op&7],1,1); break;
    case 0x50 ... 0x57: { uint16_t v=cpu.r[op&7]; if((op&7)==4) v=SP; push(v);} break;
    case 0x58 ... 0x5f: cpu.r[op&7]=pop(); break;
    case 0x60: { uint16_t t=SP; push(AX);push(CX);push(DX);push(BX);push(t);push(BP);push(SI);push(DI);} break;
    case 0x61: DI=pop();SI=pop();BP=pop();pop();BX=pop();DX=pop();CX=pop();AX=pop(); break;
    case 0x62: decode_modrm(); break; // bound: ignore
    case 0x68: push(fetch16()); break;
    case 0x69: case 0x6b: { decode_modrm(); int16_t a=rm16(); int16_t b= op==0x69? (int16_t)fetch16(): (int8_t)fetch8(); int32_t r=(int32_t)a*b; cpu.r[modrm_reg]=r; int ov= r!=(int16_t)r; setf(FC,ov); setf(FO,ov);} break;
    case 0x6a: push((int8_t)fetch8()); break;
    case 0x6c: case 0x6d: case 0x6e: case 0x6f: string_op(op); break;
    case 0x70 ... 0x7f: { int8_t d=fetch8(); if(cond(op&15)) IP+=d; } break;
    case 0x80: case 0x82: { decode_modrm(); uint8_t b=fetch8(); uint32_t r=alu(modrm_reg,rm8(),b,0); if(modrm_reg!=7) wrm8(r);} break;
    case 0x81: { decode_modrm(); uint16_t b=fetch16(); uint32_t r=alu(modrm_reg,rm16(),b,1); if(modrm_reg!=7) wrm16(r);} break;
    case 0x83: { decode_modrm(); uint16_t b=(int8_t)fetch8(); uint32_t r=alu(modrm_reg,rm16(),b,1); if(modrm_reg!=7) wrm16(r);} break;
    case 0x84: decode_modrm(); alu(4,rm8(),*r8p(modrm_reg),0); break;
    case 0x85: decode_modrm(); alu(4,rm16(),cpu.r[modrm_reg],1); break;
    case 0x86: { decode_modrm(); uint8_t a=rm8(); wrm8(*r8p(modrm_reg)); *r8p(modrm_reg)=a; } break;
    case 0x87: { decode_modrm(); uint16_t a=rm16(); wrm16(cpu.r[modrm_reg]); cpu.r[modrm_reg]=a; } break;
    case 0x88: decode_modrm(); wrm8(*r8p(modrm_reg)); break;
    case 0x89: decode_modrm(); wrm16(cpu.r[modrm_reg]); break;
    case 0x8a: decode_modrm(); *r8p(modrm_reg)=rm8(); break;
    case 0x8b: decode_modrm(); cpu.r[modrm_reg]=rm16(); break;
    case 0x8c: decode_modrm(); wrm16(cpu.s[modrm_reg&3]); break;
    case 0x8d: decode_modrm(); cpu.r[modrm_reg]=ea_off; break;
    case 0x8e: decode_modrm(); cpu.s[modrm_reg&3]=rm16(); if((modrm_reg&3)==2) cpu.inhibit_irq=1; break;
    case 0x8f: decode_modrm(); { uint16_t v=pop(); wrm16(v);} break;
    case 0x90: break;
    case 0x91 ... 0x97: { uint16_t t=AX; AX=cpu.r[op&7]; cpu.r[op&7]=t; } break;
    case 0x98: AX=(int16_t)(int8_t)(AX&0xff); break;
    case 0x99: DX=(AX&0x8000)?0xffff:0; break;
    case 0x9a: { uint16_t o=fetch16(), s=fetch16(); push(CS); push(IP); CS=s; IP=o; ct(CS,IP);} break;
    case 0x9b: break;
    case 0x9c: push(cpu.flags|0xf002); break;
    case 0x9d: cpu.flags=(pop()&0x0fd5)|0x0002; break;
    case 0x9e: cpu.flags=(cpu.flags&0xff00)|((AX>>8)&0xd5)|2; break;
    case 0x9f: *r8p(4)=cpu.flags&0xff; break;
    case 0xa0: { int s=segovr>=0?segovr:3; *r8p(0)=rd8(cpu.s[s],fetch16()); } break;
    case 0xa1: { int s=segovr>=0?segovr:3; AX=rd16(cpu.s[s],fetch16()); } break;
    case 0xa2: { int s=segovr>=0?segovr:3; wr8(cpu.s[s],fetch16(),AX&0xff); } break;
    case 0xa3: { int s=segovr>=0?segovr:3; wr16(cpu.s[s],fetch16(),AX); } break;
    case 0xa4 ... 0xa7: case 0xaa ... 0xaf: string_op(op); break;
    case 0xa8: alu(4,AX&0xff,fetch8(),0); break;
    case 0xa9: alu(4,AX,fetch16(),1); break;
    case 0xb0 ... 0xb7: *r8p(op&7)=fetch8(); break;
    case 0xb8 ... 0xbf: cpu.r[op&7]=fetch16(); break;
    case 0xc0: { decode_modrm(); uint8_t c=fetch8(); wrm8(shift(modrm_reg,rm8(),c,0)); } break;
    case 0xc1: { decode_modrm(); uint8_t c=fetch8(); wrm16(shift(modrm_reg,rm16(),c,1)); } break;
    case 0xc2: { uint16_t n=fetch16(); IP=pop(); SP+=n; } break;
    case 0xc3: IP=pop(); break;
    case 0xc4: decode_modrm(); cpu.r[modrm_reg]=rd16(cpu.s[ea_seg],ea_off); ES=rd16(cpu.s[ea_seg],ea_off+2); break;
    case 0xc5: decode_modrm(); cpu.r[modrm_reg]=rd16(cpu.s[ea_seg],ea_off); DS=rd16(cpu.s[ea_seg],ea_off+2); break;
    case 0xc6: decode_modrm(); wrm8(fetch8()); break;
    case 0xc7: decode_modrm(); wrm16(fetch16()); break;
    case 0xc8: { uint16_t sz=fetch16(); uint8_t lv=fetch8()&31; push(BP); uint16_t fp=SP; for(int i=1;i<lv;i++){BP-=2; push(rd16(SS,BP));} if(lv) push(fp); BP=fp; SP-=sz; } break;
    case 0xc9: SP=BP; BP=pop(); break;
    case 0xca: { uint16_t n=fetch16(); IP=pop(); CS=pop(); SP+=n; } break;
    case 0xcb: IP=pop(); CS=pop(); break;
    case 0xcc: cpu_interrupt(3); break;
    case 0xcd: cpu_interrupt(fetch8()); break;
    case 0xce: if(getf(FO)) cpu_interrupt(4); break;
    case 0xcf: IP=pop(); CS=pop(); cpu.flags=(pop()&0x0fd5)|2; break;
    case 0xd0: decode_modrm(); wrm8(shift(modrm_reg,rm8(),1,0)); break;
    case 0xd1: decode_modrm(); wrm16(shift(modrm_reg,rm16(),1,1)); break;
    case 0xd2: decode_modrm(); wrm8(shift(modrm_reg,rm8(),CX&0xff,0)); break;
    case 0xd3: decode_modrm(); wrm16(shift(modrm_reg,rm16(),CX&0xff,1)); break;
    case 0xd4: { uint8_t b=fetch8(); if(!b){divide_error();break;} uint8_t al=AX&0xff; AX=((al/b)<<8)|(al%b); szp8(AX&0xff);} break;
    case 0xd5: { uint8_t b=fetch8(); uint8_t al=(AX&0xff)+(AX>>8)*b; AX=al; szp8(al);} break;
    case 0xd6: *r8p(0)=getf(FC)?0xff:0; break;
    case 0xd7: { int s=segovr>=0?segovr:3; *r8p(0)=rd8(cpu.s[s],BX+(AX&0xff)); } break;
    case 0xd8 ... 0xdf: decode_modrm(); break; // FPU escape: ignore
    case 0xe0: { int8_t d=fetch8(); CX--; if(CX && !getf(FZ)) IP+=d; } break;
    case 0xe1: { int8_t d=fetch8(); CX--; if(CX && getf(FZ)) IP+=d; } break;
    case 0xe2: { int8_t d=fetch8(); CX--; if(CX) IP+=d; } break;
    case 0xe3: { int8_t d=fetch8(); if(!CX) IP+=d; } break;
    case 0xe4: *r8p(0)=io_in8(fetch8()); break;
    case 0xe5: AX=io_in16(fetch8()); break;
    case 0xe6: io_out8(fetch8(),AX&0xff); break;
    case 0xe7: io_out16(fetch8(),AX); break;
    case 0xe8: { int16_t d=fetch16(); push(IP); IP+=d; ct(CS,IP);} break;
    case 0xe9: { int16_t d=fetch16(); IP+=d; } break;
    case 0xea: { uint16_t o=fetch16(), s=fetch16(); CS=s; IP=o; } break;
    case 0xeb: { int8_t d=fetch8(); IP+=d; } break;
    case 0xec: *r8p(0)=io_in8(DX); break;
    case 0xed: AX=io_in16(DX); break;
    case 0xee: io_out8(DX,AX&0xff); break;
    case 0xef: io_out16(DX,AX); break;
    case 0xf4: cpu.halted=1; break;
    case 0xf5: cpu.flags^=FC; break;
    case 0xf6: case 0xf7: {
      int w=op&1; decode_modrm(); uint32_t v= w? rm16(): rm8();
      switch(modrm_reg){
        case 0: case 1: alu(4,v, w?fetch16():fetch8(), w); break;
        case 2: if(w) wrm16(~v); else wrm8(~v); break;
        case 3: { uint32_t r=alu(5,0,v,w); if(w) wrm16(r); else wrm8(r); setf(FC,v!=0);} break;
        case 4: if(w){ uint32_t r=(uint32_t)AX*v; AX=r; DX=r>>16; setf(FC,DX!=0); setf(FO,DX!=0);} else { uint16_t r=(AX&0xff)*v; AX=r; setf(FC,r>>8); setf(FO,r>>8);} break;
        case 5: if(w){ int32_t r=(int32_t)(int16_t)AX*(int16_t)v; AX=r; DX=r>>16; int o= r!=(int16_t)r; setf(FC,o); setf(FO,o);} else { int16_t r=(int8_t)(AX&0xff)*(int8_t)v; AX=r; int o= r!=(int8_t)r; setf(FC,o); setf(FO,o);} break;
        case 6: if(w){ uint32_t n=((uint32_t)DX<<16)|AX; if(!v||n/v>0xffff){divide_error();break;} AX=n/v; DX=n%v; } else { if(!v||AX/v>0xff){divide_error();break;} uint16_t n=AX; AX=((n%v)<<8)|(n/v);} break;
        case 7: if(w){ int32_t n=(int32_t)(((uint32_t)DX<<16)|AX); int16_t d=v; if(!d){divide_error();break;} int32_t q=n/d; if(q>32767||q<-32768){divide_error();break;} AX=q; DX=n%d; } else { int16_t n=AX; int8_t d=v; if(!d){divide_error();break;} int16_t q=n/d; if(q>127||q<-128){divide_error();break;} AX=((uint8_t)(n%d)<<8)|(uint8_t)q; } break;
      }
    } break;
    case 0xf8: setf(FC,0); break; case 0xf9: setf(FC,1); break;
    case 0xfa: setf(FI,0); break; case 0xfb: setf(FI,1); cpu.inhibit_irq=1; if(getenv("STI")) fprintf(stderr,"sti @%04x:%04x\n",insn_start_cs,insn_start_ip); break;
    case 0xfc: setf(FD,0); break; case 0xfd: setf(FD,1); break;
    case 0xfe: decode_modrm(); if(modrm_reg<2) wrm8(inc_dec(rm8(),modrm_reg,0)); else { emu_fault("bad FE /%d",modrm_reg); return -1;} break;
    case 0xff: decode_modrm();
      switch(modrm_reg){
        case 0: wrm16(inc_dec(rm16(),0,1)); break;
        case 1: wrm16(inc_dec(rm16(),1,1)); break;
        case 2: { uint16_t t=rm16(); push(IP); IP=t; ct(CS,IP);} break;
        case 3: { uint16_t o=rd16(cpu.s[ea_seg],ea_off), s=rd16(cpu.s[ea_seg],ea_off+2); push(CS); push(IP); CS=s; IP=o; ct(CS,IP);} break;
        case 4: IP=rm16(); break;
        case 5: { uint16_t o=rd16(cpu.s[ea_seg],ea_off), s=rd16(cpu.s[ea_seg],ea_off+2); CS=s; IP=o; } break;
        case 6: push(rm16()); break;
        default: emu_fault("bad FF /7"); return -1;
      } break;
    default:
      emu_fault("unimplemented opcode %02x at %04x:%04x",op,insn_start_cs,insn_start_ip); return -1;
  }
  return 0;
}
