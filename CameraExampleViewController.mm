// Copyright 2015 Google Inc. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import <AssertMacros.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import "CameraExampleViewController.h"
#import "PokedexListViewController.h"

#include <sys/time.h>

#include "tensorflow_utils.h"
#import "DexViewController.h"
// If you have your own model, modify this to the file name, and make sure
// you've added the file to your app resources too.
static NSString* model_file_name = @"retrained_graph";
static NSString* model_file_type = @"pb";
// This controls whether we'll be loading a plain GraphDef proto, or a
// file created by the convert_graphdef_memmapped_format utility that wraps a
// GraphDef and parameter file that can be mapped into memory from file to
// reduce overall memory usage.
const bool model_uses_memory_mapping = false;
// If you have your own model, point this to the labels file.
static NSString* labels_file_name = @"retrained_labels";
static NSString* labels_file_type = @"txt";
// These dimensions need to match those the model was trained with.
const int wanted_input_width = 224;
const int wanted_input_height = 224;
const int wanted_input_channels = 3;
const float input_mean = 117.0f;
const float input_std = 1.0f;
const std::string input_layer_name = "input";
const std::string output_layer_name = "final_result";
NSString *topPokemon = @"bulbasaur";

NSDictionary *types = @{
                        @"Bug": @"152 172 26",
                        @"Dragon": @"91 16 246",
                        @"Ice": @"136 209 206",
                        @"Fighting": @"176 29 31",
                        @"Fire": @"234 107 38",
                        @"Flying": @"151 119 236",
                        @"Grass": @"103 192 63",
                        @"Ghost": @"92 67 134",
                        @"Ground": @"216 180 86",
                        @"Electric": @"245 199 39",
                        @"Normal": @"152 153 101",
                        @"Poison": @"140 40 142",
                        @"Psychic": @"244 61 117",
                        @"Rock": @"169 145 44",
                        @"Water": @"86 121 236",
                        };

static void *AVCaptureStillImageIsCapturingStillImageContext =
    &AVCaptureStillImageIsCapturingStillImageContext;

@interface CameraExampleViewController (InternalMethods)
- (void)setupAVCapture;
- (void)teardownAVCapture;
@end

@implementation CameraExampleViewController

- (void)setupAVCapture {
  NSError *error = nil;

  session = [AVCaptureSession new];
  if ([[UIDevice currentDevice] userInterfaceIdiom] ==
      UIUserInterfaceIdiomPhone)
    [session setSessionPreset:AVCaptureSessionPreset640x480];
  else
    [session setSessionPreset:AVCaptureSessionPresetPhoto];

  AVCaptureDevice *device =
      [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  AVCaptureDeviceInput *deviceInput =
      [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
  assert(error == nil);

  isUsingFrontFacingCamera = NO;
  if ([session canAddInput:deviceInput]) [session addInput:deviceInput];

  stillImageOutput = [AVCaptureStillImageOutput new];
  [stillImageOutput
      addObserver:self
       forKeyPath:@"capturingStillImage"
          options:NSKeyValueObservingOptionNew
          context:(void *)(AVCaptureStillImageIsCapturingStillImageContext)];
  if ([session canAddOutput:stillImageOutput])
    [session addOutput:stillImageOutput];

  videoDataOutput = [AVCaptureVideoDataOutput new];

  NSDictionary *rgbOutputSettings = [NSDictionary
      dictionaryWithObject:[NSNumber numberWithInt:kCMPixelFormat_32BGRA]
                    forKey:(id)kCVPixelBufferPixelFormatTypeKey];
  [videoDataOutput setVideoSettings:rgbOutputSettings];
  [videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
  videoDataOutputQueue =
      dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);
  [videoDataOutput setSampleBufferDelegate:self queue:videoDataOutputQueue];

  if ([session canAddOutput:videoDataOutput])
    [session addOutput:videoDataOutput];
  [[videoDataOutput connectionWithMediaType:AVMediaTypeVideo] setEnabled:YES];

  previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:session];
  [previewLayer setBackgroundColor:[[UIColor blackColor] CGColor]];
  [previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
  CALayer *rootLayer = [previewView layer];
  [rootLayer setMasksToBounds:YES];
  [previewLayer setFrame:[rootLayer bounds]];
  [rootLayer addSublayer:previewLayer];
  [session startRunning];
  
    rootLayer.zPosition = -3;
  if (error) {
    NSString *title = [NSString stringWithFormat:@"Failed with error %d", (int)[error code]];
    UIAlertController *alertController =
        [UIAlertController alertControllerWithTitle:title
                                            message:[error localizedDescription]
                                     preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *dismiss =
        [UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleDefault handler:nil];
    [alertController addAction:dismiss];
    [self presentViewController:alertController animated:YES completion:nil];
    [self teardownAVCapture];
  }
//    CATextLayer *background = [CATextLayer layer];
//    background.zPosition = -2;
//     [background setBackgroundColor:[UIColor colorWithRed:194/255.0f green:86/255.0f blue:57/255.0f alpha:1.0f].CGColor];
//    const CGRect backgroundBounds = CGRectMake(9,11,302,110);
//    [background setFrame:backgroundBounds];
//    [[self.view layer] addSublayer: background];
}

- (void)teardownAVCapture {
  [stillImageOutput removeObserver:self forKeyPath:@"isCapturingStillImage"];
  [previewLayer removeFromSuperlayer];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (context == AVCaptureStillImageIsCapturingStillImageContext) {
    BOOL isCapturingStillImage =
        [[change objectForKey:NSKeyValueChangeNewKey] boolValue];

    if (isCapturingStillImage) {
      // do flash bulb like animation
      flashView = [[UIView alloc] initWithFrame:[previewView frame]];
      [flashView setBackgroundColor:[UIColor whiteColor]];
      [flashView setAlpha:0.f];
      [[[self view] window] addSubview:flashView];

      [UIView animateWithDuration:.4f
                       animations:^{
                         [flashView setAlpha:1.f];
                       }];
    } else {
      [UIView animateWithDuration:.4f
          animations:^{
            [flashView setAlpha:0.f];
          }
          completion:^(BOOL finished) {
            [flashView removeFromSuperview];
            flashView = nil;
          }];
    }
  }
}

- (AVCaptureVideoOrientation)avOrientationForDeviceOrientation:
    (UIDeviceOrientation)deviceOrientation {
  AVCaptureVideoOrientation result =
      (AVCaptureVideoOrientation)(deviceOrientation);
  if (deviceOrientation == UIDeviceOrientationLandscapeLeft)
    result = AVCaptureVideoOrientationLandscapeRight;
  else if (deviceOrientation == UIDeviceOrientationLandscapeRight)
    result = AVCaptureVideoOrientationLandscapeLeft;
  return result;
}

- (IBAction)takePicture:(id)sender {
  if ([session isRunning]) {
    [session stopRunning];
    [sender setTitle:@"Cancel" forState:UIControlStateNormal];
//      UIButton *subBtn = (UIButton *) [self.view viewWithTag:5];
//      subBtn.hidden = false;
    flashView = [[UIView alloc] initWithFrame:[previewView frame]];
    [flashView setBackgroundColor:[UIColor whiteColor]];
    [flashView setAlpha:0.f];
    [[[self view] window] addSubview:flashView];

    [UIView animateWithDuration:.2f
        animations:^{
          [flashView setAlpha:1.f];
        }
        completion:^(BOOL finished) {
          [UIView animateWithDuration:.2f
              animations:^{
                [flashView setAlpha:0.f];
              }
              completion:^(BOOL finished) {
                [flashView removeFromSuperview];
                flashView = nil;
              }];
        }];

  } else {
    [session startRunning];
    [sender setTitle:@"Capture" forState:UIControlStateNormal];
//      UIButton *subBtn = (UIButton *) [self.view viewWithTag:5];
//      subBtn.hidden = true;
  }
}

+ (CGRect)videoPreviewBoxForGravity:(NSString *)gravity
                          frameSize:(CGSize)frameSize
                       apertureSize:(CGSize)apertureSize {
  CGFloat apertureRatio = apertureSize.height / apertureSize.width;
  CGFloat viewRatio = frameSize.width / frameSize.height;

  CGSize size = CGSizeZero;
  if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
    if (viewRatio > apertureRatio) {
      size.width = frameSize.width;
      size.height =
          apertureSize.width * (frameSize.width / apertureSize.height);
    } else {
      size.width =
          apertureSize.height * (frameSize.height / apertureSize.width);
      size.height = frameSize.height;
    }
  } else if ([gravity isEqualToString:AVLayerVideoGravityResizeAspect]) {
    if (viewRatio > apertureRatio) {
      size.width =
          apertureSize.height * (frameSize.height / apertureSize.width);
      size.height = frameSize.height;
    } else {
      size.width = frameSize.width;
      size.height =
          apertureSize.width * (frameSize.width / apertureSize.height);
    }
  } else if ([gravity isEqualToString:AVLayerVideoGravityResize]) {
    size.width = frameSize.width;
    size.height = frameSize.height;
  }

  CGRect videoBox;
  videoBox.size = size;
  if (size.width < frameSize.width)
    videoBox.origin.x = (frameSize.width - size.width) / 2;
  else
    videoBox.origin.x = (size.width - frameSize.width) / 2;

  if (size.height < frameSize.height)
    videoBox.origin.y = (frameSize.height - size.height) / 2;
  else
    videoBox.origin.y = (size.height - frameSize.height) / 2;
    
  return videoBox;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  CFRetain(pixelBuffer);
  [self runCNNOnFrame:pixelBuffer];
  CFRelease(pixelBuffer);
}

- (void)runCNNOnFrame:(CVPixelBufferRef)pixelBuffer {
  assert(pixelBuffer != NULL);

  OSType sourcePixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
  int doReverseChannels;
  if (kCVPixelFormatType_32ARGB == sourcePixelFormat) {
    doReverseChannels = 1;
  } else if (kCVPixelFormatType_32BGRA == sourcePixelFormat) {
    doReverseChannels = 0;
  } else {
    assert(false);  // Unknown source format
  }

  const int sourceRowBytes = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
  const int image_width = (int)CVPixelBufferGetWidth(pixelBuffer);
  const int fullHeight = (int)CVPixelBufferGetHeight(pixelBuffer);

  CVPixelBufferLockFlags unlockFlags = kNilOptions;
  CVPixelBufferLockBaseAddress(pixelBuffer, unlockFlags);

  unsigned char *sourceBaseAddr =
      (unsigned char *)(CVPixelBufferGetBaseAddress(pixelBuffer));
  int image_height;
  unsigned char *sourceStartAddr;
  if (fullHeight <= image_width) {
    image_height = fullHeight;
    sourceStartAddr = sourceBaseAddr;
  } else {
    image_height = image_width;
    const int marginY = ((fullHeight - image_width) / 2);
    sourceStartAddr = (sourceBaseAddr + (marginY * sourceRowBytes));
  }
  const int image_channels = 4;

  assert(image_channels >= wanted_input_channels);
  tensorflow::Tensor image_tensor(
      tensorflow::DT_FLOAT,
      tensorflow::TensorShape(
          {1, wanted_input_height, wanted_input_width, wanted_input_channels}));
  auto image_tensor_mapped = image_tensor.tensor<float, 4>();
  tensorflow::uint8 *in = sourceStartAddr;
  float *out = image_tensor_mapped.data();
  for (int y = 0; y < wanted_input_height; ++y) {
    float *out_row = out + (y * wanted_input_width * wanted_input_channels);
    for (int x = 0; x < wanted_input_width; ++x) {
      const int in_x = (y * image_width) / wanted_input_width;
      const int in_y = (x * image_height) / wanted_input_height;
      tensorflow::uint8 *in_pixel =
          in + (in_y * image_width * image_channels) + (in_x * image_channels);
      float *out_pixel = out_row + (x * wanted_input_channels);
      for (int c = 0; c < wanted_input_channels; ++c) {
        out_pixel[c] = (in_pixel[c] - input_mean) / input_std;
      }
    }
  }

  CVPixelBufferUnlockBaseAddress(pixelBuffer, unlockFlags);

  if (tf_session.get()) {
    std::vector<tensorflow::Tensor> outputs;
    tensorflow::Status run_status = tf_session->Run(
        {{input_layer_name, image_tensor}}, {output_layer_name}, {}, &outputs);
    if (!run_status.ok()) {
      LOG(ERROR) << "Running model failed:" << run_status;
    } else {
      tensorflow::Tensor *output = &outputs[0];
      auto predictions = output->flat<float>();

      NSMutableDictionary *newValues = [NSMutableDictionary dictionary];
      for (int index = 0; index < predictions.size(); index += 1) {
        const float predictionValue = predictions(index);
        if (predictionValue > 0.05f) {
          std::string label = labels[index % predictions.size()];
          NSString *labelObject = [NSString stringWithUTF8String:label.c_str()];
          NSNumber *valueObject = [NSNumber numberWithFloat:predictionValue];
          [newValues setObject:valueObject forKey:labelObject];
        }
      }
      dispatch_async(dispatch_get_main_queue(), ^(void) {
        [self setPredictionValues:newValues];
      });
    }
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

- (void)dealloc {
  [self teardownAVCapture];
}

// use front/back camera
- (IBAction)switchCameras:(id)sender {
    
  AVCaptureDevicePosition desiredPosition;
  if (isUsingFrontFacingCamera)
    desiredPosition = AVCaptureDevicePositionBack;
  else
    desiredPosition = AVCaptureDevicePositionFront;

  for (AVCaptureDevice *d in
       [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
    if ([d position] == desiredPosition) {
      [[previewLayer session] beginConfiguration];
      AVCaptureDeviceInput *input =
          [AVCaptureDeviceInput deviceInputWithDevice:d error:nil];
      for (AVCaptureInput *oldInput in [[previewLayer session] inputs]) {
        [[previewLayer session] removeInput:oldInput];
      }
      [[previewLayer session] addInput:input];
      [[previewLayer session] commitConfiguration];
      break;
    }
  }
  isUsingFrontFacingCamera = !isUsingFrontFacingCamera;
}

- (void)didReceiveMemoryWarning {
  [super didReceiveMemoryWarning];
}

- (void)viewDidLoad {
  [super viewDidLoad];
    
  square = [UIImage imageNamed:@"test"];
  synth = [[AVSpeechSynthesizer alloc] init];
  labelLayers = [[NSMutableArray alloc] init];
  oldPredictionValues = [[NSMutableDictionary alloc] init];

  tensorflow::Status load_status;
  if (model_uses_memory_mapping) {
    load_status = LoadMemoryMappedModel(
        model_file_name, model_file_type, &tf_session, &tf_memmapped_env);
  } else {
    load_status = LoadModel(model_file_name, model_file_type, &tf_session);
  }
  if (!load_status.ok()) {
    LOG(FATAL) << "Couldn't load model: " << load_status;
  }

  tensorflow::Status labels_status =
      LoadLabels(labels_file_name, labels_file_type, &labels);
  if (!labels_status.ok()) {
    LOG(FATAL) << "Couldn't load labels: " << labels_status;
  }
    self.navigationController.navigationBar.tintColor = [UIColor whiteColor]; 
  [self setupAVCapture];
    UIButton *button = (UIButton *)[self.view viewWithTag:8];
    
    button.enabled = false;
    button.alpha = .5;
    
}

- (void)viewDidUnload {
  [super viewDidUnload];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:
    (UIInterfaceOrientation)interfaceOrientation {
  return (interfaceOrientation == UIInterfaceOrientationPortrait);
}

//- (BOOL)prefersStatusBarHidden {
//  return YES;
//}
-(UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)setPredictionValues:(NSDictionary *)newValues {
  const float decayValue = 0.75f;
  const float updateValue = 0.25f;
  const float minimumThreshold = 0.01f;

  NSMutableDictionary *decayedPredictionValues =
      [[NSMutableDictionary alloc] init];
  for (NSString *label in oldPredictionValues) {
    NSNumber *oldPredictionValueObject =
        [oldPredictionValues objectForKey:label];
    const float oldPredictionValue = [oldPredictionValueObject floatValue];
    const float decayedPredictionValue = (oldPredictionValue * decayValue);
    if (decayedPredictionValue > minimumThreshold) {
      NSNumber *decayedPredictionValueObject =
          [NSNumber numberWithFloat:decayedPredictionValue];
      [decayedPredictionValues setObject:decayedPredictionValueObject
                                  forKey:label];
    }
  }
  oldPredictionValues = decayedPredictionValues;

  for (NSString *label in newValues) {
    NSNumber *newPredictionValueObject = [newValues objectForKey:label];
    NSNumber *oldPredictionValueObject =
        [oldPredictionValues objectForKey:label];
    if (!oldPredictionValueObject) {
      oldPredictionValueObject = [NSNumber numberWithFloat:0.0f];
    }
    const float newPredictionValue = [newPredictionValueObject floatValue];
    const float oldPredictionValue = [oldPredictionValueObject floatValue];
    const float updatedPredictionValue =
        (oldPredictionValue + (newPredictionValue * updateValue));
    NSNumber *updatedPredictionValueObject =
        [NSNumber numberWithFloat:updatedPredictionValue];
    [oldPredictionValues setObject:updatedPredictionValueObject forKey:label];
  }
  NSArray *candidateLabels = [NSMutableArray array];
  for (NSString *label in oldPredictionValues) {
    NSNumber *oldPredictionValueObject =
        [oldPredictionValues objectForKey:label];
    const float oldPredictionValue = [oldPredictionValueObject floatValue];
    if (oldPredictionValue > 0.05f) {
      NSDictionary *entry = @{
        @"label" : label,
        @"value" : oldPredictionValueObject
      };
      candidateLabels = [candidateLabels arrayByAddingObject:entry];
    }
  }
  NSSortDescriptor *sort =
      [NSSortDescriptor sortDescriptorWithKey:@"value" ascending:NO];
  NSArray *sortedLabels = [candidateLabels
      sortedArrayUsingDescriptors:[NSArray arrayWithObject:sort]];

  const float leftMargin = 10.0f;
  const float topMargin = 70.0f;

  const float labelWidth = CGRectGetWidth(self.view.bounds);
  const float labelHeight = 50.0f;

  const float labelMarginX = 5.0f;
  const float labelMarginY = 7.0f;

  [self removeAllLabelLayers];

  int labelCount = 0;
  for (NSDictionary *entry in sortedLabels) {
    NSString *label = [entry objectForKey:@"label"];
    NSNumber *valueObject = [entry objectForKey:@"value"];

    const float originY =
        (topMargin + ((labelHeight + labelMarginY) * labelCount));

    [self addLabelLayerWithText:[label capitalizedString]
                        originX:leftMargin
                        originY:originY
                          width:labelWidth*.6
                         height:labelHeight
                      alignment:kCAAlignmentLeft];

//    if ((labelCount == 0) && (value > 0.5f)) {
//      [self speak:[label capitalizedString]];
//    }
//      if(labelCount == 0){
//          topPokemon = label;
//      }
    labelCount += 1;
//      UIButton *button = (UIButton *)[self.view viewWithTag:8];
//      if(button.enabled == false){
//      button.enabled = true;
//      button.alpha = 1;
//      }
    if (labelCount > 3) {
      break;
    }
      //break;
  }
}

- (void)removeAllLabelLayers {
  for (UIButton *layer in labelLayers) {
    [layer removeFromSuperview];
  }
  [labelLayers removeAllObjects];
}

- (void)addLabelLayerWithText:(NSString *)text
                      originX:(float)originX
                      originY:(float)originY
                        width:(float)width
                       height:(float)height
                    alignment:(NSString *)alignment {
  CFTypeRef font = (CFTypeRef) @"Helvetica-Neue";
  const float fontSize = 20.0f;

  const float marginSizeX = 5.0f;
  const float marginSizeY = 2.0f;

  const CGRect backgroundBounds = CGRectMake(originX, originY, width, height);
    
    CGSize stringsize = [text sizeWithFont:[UIFont systemFontOfSize:fontSize]];
  const CGRect textBounds =
      CGRectMake((originX + marginSizeX), (originY + marginSizeY)+8,
                 (width - (marginSizeX)), (height));
    
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button addTarget:self
               action:@selector(setTopPokemon:)
     forControlEvents:UIControlEventTouchUpInside];
    [button setTitle:text forState:UIControlStateNormal];
    
    button.frame = textBounds;
    button.layer.cornerRadius = 5;
    button.layer.masksToBounds = true;
//    button.imageEdgeInsets = UIEdgeInsetsMake(0, -40, 0, 0);
    button.titleEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
    [button setContentHorizontalAlignment:UIControlContentHorizontalAlignmentLeft];
    NSString *imgname = [[text lowercaseString] stringByAppendingString:@"small.png"];
    [button setImage:[UIImage imageNamed:imgname] forState:UIControlStateNormal];
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    
    NSDictionary *dict = [self getJson:text];

   NSString *type = [[dict objectForKey:@"type"] componentsSeparatedByString:@" "][0];

    NSArray *arr = [[types objectForKey:type] componentsSeparatedByString:@" "];
    
    UIColor *clr = [UIColor colorWithRed:[arr[0] floatValue]/255.0f
                                        green:[arr[1] floatValue]/255.0f
                                         blue:[arr[2] floatValue]/255.0f
                                        alpha:0.7f];
    button.imageView.backgroundColor = clr;
	button.backgroundColor = clr;
    
    [self.view addSubview:button];
    [labelLayers addObject:button];
    
}
-(void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender{
    DexViewController *controller = (DexViewController *)segue.destinationViewController;
    controller.pokemon = topPokemon;
}
-(void)setTopPokemon:(UIButton*)sender{
    topPokemon = [sender.currentTitle lowercaseString];
    UIButton *viewButton = (UIButton *) [self.view viewWithTag:1];
    NSString *imgname = [[topPokemon lowercaseString] stringByAppendingString:@"small.png"];

    [viewButton setImage:[UIImage imageNamed:imgname] forState:UIControlStateNormal];
    viewButton.imageEdgeInsets = UIEdgeInsetsMake(5, 5, 5, 5);
    viewButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [viewButton setTitle:@"" forState:UIControlStateNormal];
    UIButton *button = (UIButton *)[self.view viewWithTag:8];
    button.enabled = true;
    button.alpha = 1;
    
    NSDictionary *dict = [self getJson:topPokemon];
    
    NSString *type = [[dict objectForKey:@"type"] componentsSeparatedByString:@" "][0];
    
    NSArray *arr = [[types objectForKey:type] componentsSeparatedByString:@" "];
    
    UIColor *clr = [UIColor colorWithRed:[arr[0] floatValue]/255.0f
                                   green:[arr[1] floatValue]/255.0f
                                    blue:[arr[2] floatValue]/255.0f
                                   alpha:1.0f];

    [viewButton setBackgroundColor:clr];
    
}
- (NSDictionary *)getJson:(NSString *)name{
    @try{
    NSString *path = [[NSBundle mainBundle] pathForResource:[[name stringByReplacingOccurrencesOfString:@" " withString:@"-"] lowercaseString] ofType:@"json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    return [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
    }@catch(NSException *e){
        
    }
}
@end
#import <QuartzCore/QuartzCore.h>
@implementation CALayer (Additions)

- (void)setBorderColorFromUIColor:(UIColor *)color
{
    self.borderColor = color.CGColor;
}

@end

