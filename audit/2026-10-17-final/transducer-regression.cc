#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <string>
#include "sherpa-onnx/csrc/offline-transducer-greedy-search-decoder.h"
int main(int argc,char **argv) {
 assert(argc==2);
 std::string root=argv[1];
 for (const std::string name : {"valid","mismatch","zero-vocab","zero-context","wrong-type"}) {
  bool rejected=false;
  try {
   sherpa_onnx::OfflineModelConfig cfg;
   cfg.transducer.encoder_filename=root+"/"+name+"/encoder.onnx";
   cfg.transducer.decoder_filename=root+"/"+name+"/decoder.onnx";
   cfg.transducer.joiner_filename=root+"/"+name+"/joiner.onnx";
   cfg.num_threads=1;
   cfg.provider="cpu:"+root+"/no-arena.config";
   sherpa_onnx::OfflineTransducerModel model(cfg);
   sherpa_onnx::OfflineTransducerGreedySearchDecoder decoder(&model, -1, 0);
   auto mem=Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator,OrtMemTypeDefault);
   float features[2]={0,0};int64_t length[1]={1};int64_t fs[3]={1,1,2},ls[1]={1};
   auto x=Ort::Value::CreateTensor<float>(mem,features,2,fs,3);
   auto lens=Ort::Value::CreateTensor<int64_t>(mem,length,1,ls,1);
   auto result=decoder.Decode(std::move(x),std::move(lens));
   assert(result.size()==1);
  } catch(const std::invalid_argument& e) {
   rejected=true;std::printf("Rejected %s: %s\n",name.c_str(),e.what());
  }
  assert(rejected==(name!="valid"));
 }
 puts("PASS: actual greedy decoder rejects mismatched vocabulary, zero metadata and wrong output type; valid control decodes.");
}
