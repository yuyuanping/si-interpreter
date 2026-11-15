// Bridging header: exposes the llama.cpp C ABI bridge to Swift.
// sherpa-onnx needs no bridging — SherpaOnnxC.xcframework ships its own module map,
// so Swift files `import SherpaOnnxC` directly.
#import "si_mt_ios.h"
