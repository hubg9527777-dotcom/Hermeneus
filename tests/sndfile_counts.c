/* Exercise real parsing through bounded virtual I/O, without a gigabyte fixture. */
#include <sndfile.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
typedef struct { unsigned char header[60]; sf_count_t pos, length; } Input;
static sf_count_t length(void *p){return ((Input*)p)->length;}
static sf_count_t tell(void *p){return ((Input*)p)->pos;}
static sf_count_t seek(sf_count_t off,int whence,void*p){Input*i=p;sf_count_t n=off+(whence==SEEK_CUR?i->pos:whence==SEEK_END?i->length:0);if(n<0||n>i->length)return -1;return i->pos=n;}
static sf_count_t read_bytes(void *out,sf_count_t n,void*p){Input*i=p;if(n>i->length-i->pos)n=i->length-i->pos;memset(out,0,(size_t)n);if(i->pos<60){sf_count_t h=60-i->pos;if(h>n)h=n;memcpy(out,i->header+i->pos,(size_t)h);}i->pos+=n;return n;}
static sf_count_t write_bytes(const void *a,sf_count_t b,void*c){(void)a;(void)b;(void)c;return 0;}
static void le(unsigned char*p,uint32_t x,int n){for(int i=0;i<n;i++)p[i]=(unsigned char)(x>>(i*8));}
int main(int argc,char**argv){
 if(argc>1){SF_INFO s={0};SNDFILE*f=sf_open(argv[1],SFM_READ,&s);int valid=strstr(argv[1],"valid")!=NULL;
  if(valid){if(!f||s.samplerate!=16000||s.channels!=1||s.frames!=16)return 10;short a[16];if(sf_readf_short(f,a,16)!=16)return 11;}
  else if(f){sf_close(f);fprintf(stderr,"Malformed IRCAM accepted: %s\n",argv[1]);return 12;}
  if(f)sf_close(f);return 0;}
 Input i={0};uint32_t blocks=5000000, bytes=blocks*256u;i.length=60+(sf_count_t)bytes;
 unsigned char*h=i.header;memcpy(h,"RIFF",4);le(h+4,bytes+52,4);memcpy(h+8,"WAVEfmt ",8);le(h+16,20,4);le(h+20,17,2);le(h+22,1,2);le(h+24,16000,4);le(h+28,8110,4);le(h+32,256,2);le(h+34,4,2);le(h+36,2,2);le(h+38,505,2);memcpy(h+40,"fact",4);le(h+44,4,4);le(h+48,blocks*505u,4);memcpy(h+52,"data",4);le(h+56,bytes,4);
 SF_VIRTUAL_IO io={length,seek,read_bytes,write_bytes,tell};SF_INFO s={0};SNDFILE*f=sf_open_virtual(&io,SFM_READ,&s,&i);
 if(!f){fprintf(stderr,"virtual WAV: %s\n",sf_strerror(NULL));return 1;}
 if(s.frames!=(sf_count_t)blocks*505){fprintf(stderr,"Wrong frame count: %lld\n",(long long)s.frames);return 2;}
 short sample[16];if(sf_readf_short(f,sample,16)!=16)return 3;sf_close(f);puts("PASS: 64-bit IMA frame count using bounded virtual I/O");return 0;
}
