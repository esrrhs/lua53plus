/* Identical public-API workload for lua53plus and PUC-Lua 5.3.4. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <sys/resource.h>
#ifndef __APPLE__
#include <unistd.h>
#endif
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_time.h>
#endif
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lobject.h" /* sizeof-only layout accounting, never collector controls */
#include "lfunc.h"
typedef struct Memory { size_t live, peak; } Memory;
static void *mem(void *ud,void *p,size_t old,size_t n) {
  Memory *m=ud; void *q;
  if (!p) old=0;
  if (!n) { free(p); m->live-=old; return NULL; }
  q=realloc(p,n);
  if (q) { m->live=m->live-old+n; if(m->live>m->peak)m->peak=m->live; }
  return q;
}
static double now(void) {
#ifdef __APPLE__
  mach_timebase_info_data_t t; mach_timebase_info(&t);
  return (double)mach_absolute_time()*(double)t.numer/(double)t.denom/1e9;
#else
  struct timespec t; if(clock_gettime(CLOCK_MONOTONIC,&t)) abort();
  return (double)t.tv_sec+(double)t.tv_nsec/1e9;
#endif
}
static size_t rss(void) {
#ifdef __APPLE__
  struct mach_task_basic_info t; mach_msg_type_number_t n=MACH_TASK_BASIC_INFO_COUNT;
  if(task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&t,&n)!=KERN_SUCCESS) abort();
  return (size_t)t.resident_size;
#else
  FILE *f=fopen("/proc/self/statm","r"); unsigned long pages, resident;
  if(!f || fscanf(f,"%lu %lu",&pages,&resident)!=2) abort();
  fclose(f);
  return resident*(size_t)sysconf(_SC_PAGESIZE);
#endif
}
static int cmp(const void *a,const void *b) {
  double x=*(const double *)a,y=*(const double *)b; return (x>y)-(x<y);
}
static void call(lua_State *L) {
  lua_getglobal(L,"tick");
  if(lua_pcall(L,0,0,0)) { fprintf(stderr,"%s\n",lua_tostring(L,-1));exit(1); }
}
int main(int argc,char **argv) {
  int i,n=argc>1?atoi(argv[1]):3000;
  Memory m={0,0}; lua_State *L=lua_newstate(mem,&m);
  double *pauses,*batches,start,end,elapsed,drain; size_t live,resident,peakrss,postcollect;
  struct rusage usage;
  if(!L || n<100) return 1;
  pauses=malloc(sizeof(double)*(size_t)n); batches=malloc(sizeof(double)*(size_t)n);
  if(!pauses || !batches) return 1;
  luaL_openlibs(L); lua_gc(L,LUA_GCSTOP,0);
  if(luaL_dostring(L,
    "r={}; for i=1,20000 do r[i]={id=i} end; seed=101; "
    "function tick() for i=1,64 do seed=(seed*48271)%2147483647; "
    "local k=seed%20000+1; r[k].young={id=seed,child={seed+1,seed+2}} end end")) return 1;
  for(i=0;i<500;i++) {call(L);lua_gc(L,LUA_GCSTEP,0);}
  lua_gc(L,LUA_GCCOLLECT,0); m.peak=m.live;
  start=now();
  for(i=0;i<n;i++) {
    double a=now(),b;
    call(L); b=now(); batches[i]=(b-a)*1e6;
    lua_gc(L,LUA_GCSTEP,0); pauses[i]=(now()-b)*1e6;
  }
  end=now(); elapsed=end-start; live=m.live; resident=rss();
  getrusage(RUSAGE_SELF,&usage); peakrss=(size_t)usage.ru_maxrss;
#ifndef __APPLE__
  peakrss*=1024;
#endif
  start=now(); lua_gc(L,LUA_GCCOLLECT,0); lua_gc(L,LUA_GCCOLLECT,0);
  drain=now()-start; postcollect=m.live;
  qsort(pauses,(size_t)n,sizeof(double),cmp); qsort(batches,(size_t)n,sizeof(double),cmp);
  printf("{\"samples\":%d,\"seed\":101,\"seconds\":%.9f,\"gc_p99_us\":%.6f,\"gc_max_us\":%.6f,\"batch_p99_us\":%.6f,\"batch_max_us\":%.6f,\"lua_peak_bytes\":%zu,\"lua_live_bytes\":%zu,\"rss_bytes\":%zu,\"rss_peak_bytes\":%zu,\"sizeof_table\":%zu,\"sizeof_udata\":%zu,\"sizeof_upval\":%zu",n,elapsed,pauses[(99*n+99)/100-1],pauses[n-1],batches[(99*n+99)/100-1],batches[n-1],m.peak,live,resident,peakrss,sizeof(Table),sizeof(Udata),sizeof(UpVal));
  printf(",\"drain_full_gc_us\":%.6f,\"seconds_with_drain\":%.9f,\"lua_post_collect_bytes\":%zu}\n",drain*1e6,elapsed+drain,postcollect);
  lua_close(L); free(pauses); free(batches); return m.live ? 1:0;
}
