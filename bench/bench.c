#define _GNU_SOURCE
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#define WG 4096
#define LS 64
#define NELEM (WG*LS)
static int ITER=16384, UNROLL=16, FAST=0;
#define TOTAL_DOTS ((uint64_t)NELEM*ITER*UNROLL)


#define CHECK(x) do { VkResult r=(x); if(r!=VK_SUCCESS){fprintf(stderr,"Vulkan error %d at %s:%d\n",r,__FILE__,__LINE__); exit(1);} } while(0)

static double now_ms(void){struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);return ts.tv_sec*1e3+ts.tv_nsec/1e6;}

static int cmpd(const void*a,const void*b){double x=*(const double*)a,y=*(const double*)b;return (x>y)-(x<y);}

static uint32_t dot_one(uint32_t a,uint32_t b,int as_signed,int bs_signed){
  int64_t s=0;
  for(int i=0;i<4;i++){
    int64_t av=as_signed?(int8_t)((a>>(8*i))&0xff):(uint8_t)((a>>(8*i))&0xff);
    int64_t bv=bs_signed?(int8_t)((b>>(8*i))&0xff):(uint8_t)((b>>(8*i))&0xff);
    s+=av*bv;
  }
  return (uint32_t)s;
}
static uint32_t rep(uint32_t x){uint32_t b=x&255;return b|(b<<8)|(b<<16)|(b<<24);}
/* simula exatamente o kernel para uma lane */
static uint32_t dot_cpu(const uint32_t*A,const uint32_t*B,uint32_t lane,const char*k){
  int as=1,bs=1;
  if(!strcmp(k,"udot")){as=0;bs=0;} else if(!strcmp(k,"sudot")){bs=0;}
  uint32_t acc=0;
  const uint32_t *pa=A+(size_t)lane*UNROLL, *pb=B+(size_t)lane*UNROLL;
  for(uint32_t i=0;i<ITER;i++){
    uint32_t m=rep(i);
    for(int kk=0;kk<UNROLL;kk++){
      uint32_t d=dot_one(pa[kk]^m,pb[kk],as,bs);
      acc+=d;
    }
  }
  return acc;
}

int main(int argc,char**argv){
  if(argc<3){fprintf(stderr,"usage: %s kernel.spv sdot|udot|sudot [ITER] [UNROLL] [fast]\n",argv[0]);return 2;}
  if(argc>3) ITER=atoi(argv[3]);
  if(argc>4) UNROLL=atoi(argv[4]);
  if(argc>5) FAST=1;
  const char*kind=argv[2];

  VkApplicationInfo ai={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_3};
  VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&ai};
  VkInstance inst; CHECK(vkCreateInstance(&ici,NULL,&inst));

  uint32_t np=0; vkEnumeratePhysicalDevices(inst,&np,NULL);
  VkPhysicalDevice *pds=malloc(np*sizeof(*pds)); vkEnumeratePhysicalDevices(inst,&np,pds);
  VkPhysicalDevice pd=VK_NULL_HANDLE;
  for(uint32_t i=0;i<np;i++){VkPhysicalDeviceProperties p;vkGetPhysicalDeviceProperties(pds[i],&p);if(p.deviceType==VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU){pd=pds[i];break;}}
  if(!pd) pd=pds[0];

  VkPhysicalDeviceProperties2 p2={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
  VkPhysicalDeviceDriverProperties dp={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
  p2.pNext=&dp; vkGetPhysicalDeviceProperties2(pd,&p2);
  printf("device: %s\n",p2.properties.deviceName);
  printf("driver: %s %s\n",dp.driverName,dp.driverInfo);

  uint32_t qn=0; vkGetPhysicalDeviceQueueFamilyProperties(pd,&qn,NULL);
  VkQueueFamilyProperties *qp=malloc(qn*sizeof(*qp)); vkGetPhysicalDeviceQueueFamilyProperties(pd,&qn,qp);
  uint32_t qf=UINT32_MAX;
  for(uint32_t i=0;i<qn;i++) if(qp[i].queueFlags&VK_QUEUE_COMPUTE_BIT){qf=i;break;}
  if(qf==UINT32_MAX){fprintf(stderr,"no compute queue\n");return 1;}

  float prio=0.f;
  VkDeviceQueueCreateInfo qci={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=qf,.queueCount=1,.pQueuePriorities=&prio};
  VkDeviceCreateInfo dci={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qci};
  VkDevice dev; CHECK(vkCreateDevice(pd,&dci,NULL,&dev));
  VkQueue queue; vkGetDeviceQueue(dev,qf,0,&queue);

  VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd,&mp);
  uint32_t mt=UINT32_MAX;
  for(uint32_t i=0;i<mp.memoryTypeCount;i++)
    if(mp.memoryTypes[i].propertyFlags&(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)){mt=i;break;}
  if(mt==UINT32_MAX){fprintf(stderr,"no host-visible mem\n");return 1;}

  VkBuffer bufs[3]; VkDeviceMemory mems[3]; uint32_t *maps[3];
  size_t szAB=(size_t)NELEM*UNROLL*sizeof(uint32_t);
  size_t szO=NELEM*sizeof(uint32_t);
  size_t szs[3]={szAB,szAB,szO};
  for(int i=0;i<3;i++){
    VkBufferCreateInfo bi={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=szs[i],.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,.sharingMode=VK_SHARING_MODE_EXCLUSIVE};
    CHECK(vkCreateBuffer(dev,&bi,NULL,&bufs[i]));
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev,bufs[i],&mr);
    VkMemoryAllocateInfo mai={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=mr.size,.memoryTypeIndex=mt};
    CHECK(vkAllocateMemory(dev,&mai,NULL,&mems[i]));
    CHECK(vkBindBufferMemory(dev,bufs[i],mems[i],0));
    maps[i]=NULL; CHECK(vkMapMemory(dev,mems[i],0,szs[i],0,(void**)&maps[i]));
  }
  for(uint32_t i=0;i<(uint32_t)NELEM*UNROLL;i++){maps[0][i]=i*2654435761u+1u;maps[1][i]=i*2246822519u+7u;}
  for(uint32_t i=0;i<NELEM;i++) maps[2][i]=0;

  VkDescriptorSetLayoutBinding lb[3];
  for(int i=0;i<3;i++) lb[i]=(VkDescriptorSetLayoutBinding){.binding=i,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT};
  VkDescriptorSetLayoutCreateInfo dsl={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=3,.pBindings=lb};
  VkDescriptorSetLayout dslh; CHECK(vkCreateDescriptorSetLayout(dev,&dsl,NULL,&dslh));
  VkPipelineLayoutCreateInfo pli={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=1,.pSetLayouts=&dslh};
  VkPipelineLayout pl; CHECK(vkCreatePipelineLayout(dev,&pli,NULL,&pl));

  FILE*f=fopen(argv[1],"rb"); if(!f){perror("spv");return 1;}
  fseek(f,0,SEEK_END); long fl=ftell(f); fseek(f,0,SEEK_SET);
  uint32_t*code=malloc(fl); if(fread(code,1,fl,f)!=(size_t)fl)return 1; fclose(f);
  VkShaderModuleCreateInfo smi={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=fl,.pCode=code};
  VkShaderModule sm; CHECK(vkCreateShaderModule(dev,&smi,NULL,&sm));

  VkComputePipelineCreateInfo cpi={.sType=VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,.stage={.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_COMPUTE_BIT,.module=sm,.pName="main"},.layout=pl};
  VkPipeline pipe; CHECK(vkCreateComputePipelines(dev,VK_NULL_HANDLE,1,&cpi,NULL,&pipe));

  VkDescriptorPoolSize ps={.type=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=3};
  VkDescriptorPoolCreateInfo dpi={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=1,.poolSizeCount=1,.pPoolSizes=&ps};
  VkDescriptorPool pool; CHECK(vkCreateDescriptorPool(dev,&dpi,NULL,&pool));
  VkDescriptorSetAllocateInfo dai={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=pool,.descriptorSetCount=1,.pSetLayouts=&dslh};
  VkDescriptorSet set; CHECK(vkAllocateDescriptorSets(dev,&dai,&set));
  VkWriteDescriptorSet w[3];
  VkDescriptorBufferInfo binfo[3];
  for(int i=0;i<3;i++){
    binfo[i]=(VkDescriptorBufferInfo){.buffer=bufs[i],.offset=0,.range=szs[i]};
    w[i]=(VkWriteDescriptorSet){.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=set,.dstBinding=i,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&binfo[i]};
  }
  vkUpdateDescriptorSets(dev,3,w,0,NULL);

  VkCommandPool cpool; VkCommandPoolCreateInfo cpi2={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,.queueFamilyIndex=qf};
  CHECK(vkCreateCommandPool(dev,&cpi2,NULL,&cpool));
  VkCommandBuffer cb; VkCommandBufferAllocateInfo cai={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=cpool,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};
  CHECK(vkAllocateCommandBuffers(dev,&cai,&cb));
  VkCommandBufferBeginInfo bi={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
  CHECK(vkBeginCommandBuffer(cb,&bi));
  vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipe);
  vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pl,0,1,&set,0,NULL);
  vkCmdDispatch(cb,WG,1,1);
  CHECK(vkEndCommandBuffer(cb));

  VkFence fence; VkFenceCreateInfo fi={.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  CHECK(vkCreateFence(dev,&fi,NULL,&fence));

  VkSubmitInfo si={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cb};
  /* sustained warmup: spin >=1500ms to ramp GPU clocks */
  double w0=now_ms();
  if(!FAST) while(now_ms()-w0<1500.0){
    CHECK(vkResetFences(dev,1,&fence));
    CHECK(vkQueueSubmit(queue,1,&si,fence));
    CHECK(vkWaitForFences(dev,1,&fence,VK_TRUE,UINT64_MAX));
  }
  const int REPS=FAST?1:10;
  double times[REPS];
  for(int r=0;r<REPS;r++){
    CHECK(vkResetFences(dev,1,&fence));
    double t0=now_ms();
    CHECK(vkQueueSubmit(queue,1,&si,fence));
    CHECK(vkWaitForFences(dev,1,&fence,VK_TRUE,UINT64_MAX));
    double t1=now_ms();
    times[r]=t1-t0;
  }
  {
    FILE*sf=fopen("/sys/class/drm/card0/device/pp_dpm_sclk","r");
    if(!sf) sf=fopen("/sys/class/drm/card1/device/pp_dpm_sclk","r");
    if(sf){char line[256];printf("sclk: ");while(fgets(line,sizeof line,sf))printf("%s",strstr(line,"*")?line:"");fclose(sf);}
  }
  qsort(times,REPS,sizeof(double),cmpd);
  double med=times[REPS/2], best=times[0];
  printf("kind: %s  median: %.2f ms  best: %.2f ms  throughput: %.2f Gdot/s\n",
         kind,med,best,(TOTAL_DOTS/1e9)/(best/1e3));

  int bad=0;
  uint32_t nsamp=NELEM<64?NELEM:64;
  for(uint32_t i=0;i<nsamp&&bad<5;i++){
    uint32_t exp=dot_cpu(maps[0],maps[1],i,kind);
    if(maps[2][i]!=exp){ if(!bad) fprintf(stderr,"MISMATCH i=%u got=%u exp=%u\n",i,maps[2][i],exp); bad++; }
  }
  printf("verify: %s\n",bad?"FAIL":"PASS");
  return bad?1:0;
}
