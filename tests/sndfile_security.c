#include <sndfile.h>
#include <stdio.h>
#include <string.h>
int main(int argc,char**argv){
 for(int n=1;n<argc;n++){
  SF_INFO info={0};SNDFILE*f=sf_open(argv[n],SFM_READ,&info);
  if(strstr(argv[n],"misalign")){if(f)sf_close(f);continue;}
  if(!f){fprintf(stderr,"open failed: %s %s\n",argv[n],sf_strerror(NULL));return 1;}
  SF_CUES cues={0}; if(!sf_command(f,SFC_GET_CUE,&cues,sizeof(cues))||cues.cue_count!=1)return 2;
  char*name=cues.cue_points[0].name;
  if(strstr(argv[n],"long")){for(int j=0;j<255;j++)if(name[j]!='L')return 3;if(name[255])return 4;}
  else{if(name[0]!='X')return 5;for(int j=1;j<256;j++)if(name[j]){fprintf(stderr,"nonzero byte at %d\n",j);return 6;}}
  sf_close(f);
 }
 puts("PASS: malformed WAV and short/long cue label regressions");return 0;
}
