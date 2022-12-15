//
//  OpusPlayer.swift
//  xSDR6000
//
//  Created by Douglas Adams on 2/12/16.
//  Copyright © 2016 Douglas Adams. All rights reserved.
//

import Accelerate
import AudioToolbox
import AVFoundation
import ComposableArchitecture
import Foundation

import RingBuffer
import Shared
import XCGWrapper

//  DATA FLOW
//
//  Stream Handler  ->  Opus Decoder   ->   Ring Buffer   ->  OutputUnit    -> Output device
//
//                  [UInt8]            [Float]            [Float]           set by hardware
//
//                  opus               pcmFloat32         pcmFloat32
//                  24_000             24_000             24_000
//                  2 channels         2 channels         2 channels
//                                     interleaved        interleaved

// ----------------------------------------------------------------------------
// MARK: - Dependency decalarations

//extension OpusPlayer: DependencyKey {
//  public static var liveValue: OpusPlayer? = nil
//}
//
//extension DependencyValues {
//  public var opusPlayer: OpusPlayer? {
//    get {self[OpusPlayer.self]}
//    set {self[OpusPlayer.self] = newValue}
//  }
//}

public final class OpusPlayer: NSObject, StreamHandler {
  
  // ----------------------------------------------------------------------------
  // MARK: - Static properties
  
  public static let sampleRate: Double = 24_000
  public static let frameCount = 240
  public static let channelCount = 2
  public static let elementSize = MemoryLayout<Float>.size
  public static let isInterleaved = true
  public static let application = 2049
  
  static let bufferSize         = frameCount * elementSize  // size of a buffer (in Bytes)
  static let ringBufferCapacity = 20      // number of AudioBufferLists in the Ring buffer
  static let ringBufferOverage  = 2_048   // allowance for Ring buffer metadata (in Bytes)
  static let ringBufferSize     = (OpusPlayer.bufferSize * channelCount * OpusPlayer.ringBufferCapacity) + OpusPlayer.ringBufferOverage
  
  // Opus sample rate, format, 2 channels for compressed Opus data
  static var opusASBD = AudioStreamBasicDescription(mSampleRate: sampleRate,
                                                    mFormatID: kAudioFormatOpus,
                                                    mFormatFlags: 0,
                                                    mBytesPerPacket: 0,
                                                    mFramesPerPacket: UInt32(frameCount),
                                                    mBytesPerFrame: 0,
                                                    mChannelsPerFrame: UInt32(channelCount),
                                                    mBitsPerChannel: 0,
                                                    mReserved: 0)
  // Opus sample rate, PCM, Float32, 2 channel, interleaved
  static var decoderOutputASBD = AudioStreamBasicDescription(mSampleRate: sampleRate,
                                                             mFormatID: kAudioFormatLinearPCM,
                                                             mFormatFlags: kAudioFormatFlagIsFloat,
                                                             mBytesPerPacket: UInt32(elementSize * channelCount),
                                                             mFramesPerPacket: 1,
                                                             mBytesPerFrame: UInt32(elementSize * channelCount),
                                                             mChannelsPerFrame: UInt32(channelCount),
                                                             mBitsPerChannel: UInt32(elementSize * 8) ,
                                                             mReserved: 0)
  
  // ----------------------------------------------------------------------------
  // MARK: - Punlic properties
  
  public var id: StreamId?

  // ----------------------------------------------------------------------------
  // MARK: - Private properties
  
  private var _converter: AVAudioConverter?
  private var _inputBuffer = AVAudioCompressedBuffer()
//  private let _log = Logger.sharedInstance
  private var _outputActive: Bool {
    get { return _q.sync { __outputActive } }
    set { _q.sync(flags: .barrier) { __outputActive = newValue } } }
  private var _outputBuffer = AVAudioPCMBuffer()
  private var _outputUnit: AudioUnit?
  private var _q = DispatchQueue(label: "OpusPlayerObjectQ", qos: .userInteractive, attributes: [.concurrent])
  private var _ringBuffer = TPCircularBuffer()
  
  // ----------------------------------------------------------------------------
  // *** Backing properties (Do NOT use) ***
  
  private var __outputActive = false
  
  // ----------------------------------------------------------------------------
  // MARK: - Initialization
  
//  public static var shared = OpusPlayer()
  public override init() {
    super.init()
    
//    setupConversion()
//    setupOutputUnit()
  }
//  deinit {
//    guard let outputUnit = _outputUnit else { return }
//    AudioUnitUninitialize(outputUnit)
//    AudioComponentInstanceDispose(outputUnit)
//  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Public methods
  
  public func start(_ id: StreamId) {
    self.id = id

    setupConversion()
    setupOutputUnit()

    guard let outputUnit = _outputUnit else { fatalError("Output unit is null") }
    TPCircularBufferClear(&_ringBuffer)
    
//    let availableFrames = TPCircularBufferGetAvailableSpace(&_ringBuffer, &OpusPlayer.decoderOutputASBD)
//    _log.logMessage("OpusPlayer start: frames = \(availableFrames)", .debug, #function, #file, #line)
    
    // register render callback
    var input: AURenderCallbackStruct = AURenderCallbackStruct(inputProc: renderProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
    AudioUnitSetProperty(outputUnit,
                         kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Input,
                         0,
                         &input,
                         UInt32(MemoryLayout.size(ofValue: input)))
    guard AudioUnitInitialize(outputUnit) == noErr else { fatalError("Output unit not initialized") }
    
    guard AudioOutputUnitStart(_outputUnit!) == noErr else { fatalError("Output unit failed to start") }
    _outputActive = true
  }
  
  public func stop() {
    _outputActive = false
    
    guard let outputUnit = _outputUnit else { return }
    
    AudioOutputUnitStop(outputUnit)
    
//    let availableFrames = TPCircularBufferGetAvailableSpace(&_ringBuffer, &OpusPlayer.decoderOutputASBD)
//    _log.logMessage("OpusPlayer stop: frames = \(availableFrames) ", .debug, #function, #file, #line)

//    guard let outputUnit = _outputUnit else { return }
    AudioUnitUninitialize(outputUnit)
    AudioComponentInstanceDispose(outputUnit)
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Private methods
  
  /// Setup buffers and Converters
  ///
  private func setupConversion() {
    // setup the Converter Input & Output buffers
    _inputBuffer = AVAudioCompressedBuffer(format: AVAudioFormat(streamDescription: &OpusPlayer.opusASBD)!, packetCapacity: 1, maximumPacketSize: OpusPlayer.frameCount)
    _outputBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(streamDescription: &OpusPlayer.decoderOutputASBD)!, frameCapacity: UInt32(OpusPlayer.frameCount))!
    
    // convert from Opus compressed -> PCM Float32, 2 channel, interleaved
    _converter = AVAudioConverter(from: AVAudioFormat(streamDescription: &OpusPlayer.opusASBD)!,
                                  to: AVAudioFormat(streamDescription: &OpusPlayer.decoderOutputASBD)!)
    // create the Ring buffer (actual size will be adjusted to fit virtual memory page size)
    guard _TPCircularBufferInit( &_ringBuffer, UInt32(OpusPlayer.ringBufferSize), MemoryLayout<TPCircularBuffer>.stride ) else { fatalError("Ring Buffer not created") }
  }
  
  /// Setup the Output Unit
  ///
  func setupOutputUnit() {
    // create an Audio Component Description
    var outputcd = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_DefaultOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0,
                                             componentFlagsMask: 0)
    // get the output device
    guard let audioComponent = AudioComponentFindNext(nil, &outputcd) else { fatalError("Output unit not found") }
    
    // create the player's output unit
    guard AudioComponentInstanceNew(audioComponent, &_outputUnit) == noErr else { fatalError("Output unit not created") }
    guard let outputUnit = _outputUnit else { fatalError("Output unit is null") }
    
    // set the output unit's Input sample rate
    var inputSampleRate = OpusPlayer.sampleRate
    AudioUnitSetProperty(outputUnit,
                         kAudioUnitProperty_SampleRate,
                         kAudioUnitScope_Input,
                         0,
                         &inputSampleRate,
                         UInt32(MemoryLayout<Float64>.size))
    
    // set the output unit's Input stream format (PCM Float32 interleaved)
    var inputStreamFormat = OpusPlayer.decoderOutputASBD
    AudioUnitSetProperty(outputUnit,
                         kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Input,
                         0,
                         &inputStreamFormat,
                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
  }
  
  /// AudioUnit Render proc
  ///   populates PCM Float32 interleaved data into the ring buffer
  ///
  private let renderProc: AURenderCallback = { (inRefCon: UnsafeMutableRawPointer, _, _, _, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>? ) in
    guard let ioData = ioData else { fatalError("ioData is null") }
    
    // get a reference to the OpusPlayer
    let player = Unmanaged<OpusPlayer>.fromOpaque(inRefCon).takeUnretainedValue()
    
    // retrieve the requested number of frames
    var lengthInFrames = inNumberFrames
    TPCircularBufferDequeueBufferListFrames(&player._ringBuffer, &lengthInFrames, ioData, nil, &OpusPlayer.decoderOutputASBD)
    
    // assumes no error
    return noErr
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Stream Handler protocol methods
  
  /// Process the UDP Stream Data for RemoteRxAudio (Opus) streams
  /// - Parameter frame:            an Opus Rx Frame
  public func streamHandler<T>(_ streamFrame: T) {
    guard let frame = streamFrame as? RemoteRxAudioFrame else { return }
    
    // create an AVAudioCompressedBuffer for input to the converter
    _inputBuffer = AVAudioCompressedBuffer(format: AVAudioFormat(streamDescription: &OpusPlayer.opusASBD)!, packetCapacity: 1, maximumPacketSize: OpusPlayer.frameCount)
    
    // create an AVAudioPCMBuffer buffer for output from the converter
    _outputBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(streamDescription: &OpusPlayer.decoderOutputASBD)!, frameCapacity: UInt32(OpusPlayer.frameCount))!
    _outputBuffer.frameLength = _outputBuffer.frameCapacity
    
    if frame.numberOfSamples != 0 {
      // Valid packet: copy the data and save the count
      memcpy(_inputBuffer.data, frame.samples, frame.numberOfSamples)
      _inputBuffer.byteLength = UInt32(frame.numberOfSamples)
      _inputBuffer.packetCount = AVAudioPacketCount(1)
      _inputBuffer.packetDescriptions![0].mDataByteSize = _inputBuffer.byteLength
    } else {
      // Missed packet:
      _inputBuffer.byteLength = UInt32(frame.numberOfSamples)
      _inputBuffer.packetCount = AVAudioPacketCount(1)
      _inputBuffer.packetDescriptions![0].mDataByteSize = _inputBuffer.byteLength
    }
    // Convert from the inputBuffer (Opus) to the outputBuffer (PCM Float32, interleaved)
    var error: NSError?
    _ = (_converter!.convert(to: _outputBuffer, error: &error, withInputFrom: { (_, outputStatus) -> AVAudioBuffer? in
      outputStatus.pointee = .haveData
      return self._inputBuffer
    }))
    
    // check for decode errors
    if error != nil {
      fatalError("Opus conversion error: \(error!)")
    }
    // copy the frame's buffer to the Ring buffer & make it available
    TPCircularBufferCopyAudioBufferList(&_ringBuffer, &_outputBuffer.mutableAudioBufferList.pointee, nil, UInt32(OpusPlayer.frameCount), &OpusPlayer.decoderOutputASBD)
    
    // start playing
//    if _outputActive == false {
//      guard AudioOutputUnitStart(_outputUnit!) == noErr else { fatalError("Output unit failed to start") }
//      _outputActive = true
//    }
  }
}
