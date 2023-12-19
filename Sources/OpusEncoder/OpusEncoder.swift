//
//  OpusEncoder.swift
//  UtilityFeatures/OpusEncoder
//
//  Created by Douglas Adams on 8/2/18.
//  Copyright © 2018 Douglas Adams. All rights reserved.
//

import AVFoundation
import Foundation

import RingBuffer
import SharedModel
import XCGWrapper

//  DATA FLOW
//
//  Input device  ->InputNode Tap  ->AudioConverter  ->RingBuffer  ->OpusEncoder  ->RemoteTxAudioStream.sendTxAudio()
//
//                various          [Float]           [Float]       [Float]          [UInt8]
//
//                various          pcmFloat32        pcmFloat32    pcmFloat32       opus
//                various          various           24_000        24_000           24_000
//                various          various           2 channels    2 channels       2 channels
//                various          various           interleaved   interleaved

public final class OpusEncoder: NSObject {
  // ----------------------------------------------------------------------------
  // MARK: - Static properties
  
  static let sampleRate: Double = 24_000
  static let frameCount = 240
  static let channelCount = 2
  static let elementSize = MemoryLayout<Float>.size
  static let isInterleaved = true
  static let application = 2049
  
  static let bufferSize         = OpusEncoder.frameCount * OpusEncoder.elementSize  // size of a buffer (in Bytes)
  static let ringBufferCapacity = 20      // number of AudioBufferLists in the Ring buffer
  static let ringBufferOverage  = 2_048   // allowance for Ring buffer metadata (in Bytes)
  static let ringBufferSize     = (OpusEncoder.bufferSize * OpusEncoder.channelCount * OpusEncoder.ringBufferCapacity) + OpusEncoder.ringBufferOverage
  
  // PCM, 24_000, Float32, 2 channel, interleaved
  static var encoderInputASBD = AudioStreamBasicDescription(mSampleRate: OpusEncoder.sampleRate,
                                                            mFormatID: kAudioFormatLinearPCM,
                                                            mFormatFlags: kAudioFormatFlagIsFloat,
                                                            mBytesPerPacket: UInt32(OpusEncoder.elementSize * OpusEncoder.channelCount),
                                                            mFramesPerPacket: 1,
                                                            mBytesPerFrame: UInt32(OpusEncoder.elementSize * OpusEncoder.channelCount),
                                                            mChannelsPerFrame: UInt32(OpusEncoder.channelCount),
                                                            mBitsPerChannel: UInt32(OpusEncoder.elementSize * 8) ,
                                                            mReserved: 0)
  // Opus, 24_000, 2 channels, compressed
  static var encoderOutputASBD = AudioStreamBasicDescription(mSampleRate: OpusEncoder.sampleRate,
                                                             mFormatID: kAudioFormatOpus,
                                                             mFormatFlags: 0,
                                                             mBytesPerPacket: 0,
                                                             mFramesPerPacket: UInt32(OpusEncoder.frameCount),
                                                             mBytesPerFrame: 0,
                                                             mChannelsPerFrame: UInt32(OpusEncoder.channelCount),
                                                             mBitsPerChannel: 0,
                                                             mReserved: 0)
  private var _ringBuffer = TPCircularBuffer()
  private var _observations = [NSKeyValueObservation]()
  private var _opusConverter: AVAudioConverter?
  private var _ringInputBuffer = AVAudioPCMBuffer()
  private var _encoderOutputBuffer = AVAudioCompressedBuffer()
  private var _inputConverter: AVAudioConverter!
  private var _engine: AVAudioEngine?
  private var _outputActive: Bool {
    get { return _q.sync { __outputActive } }
    set { _q.sync(flags: .barrier) { __outputActive = newValue } } }
  private weak var _delegate: AudioStreamHandler?
  
  private var __outputActive = false
  private var _tapInputBlock: AVAudioNodeTapBlock!
  private var _tapBufferSize: AVAudioFrameCount = 0
  private var _bufferSemaphore: DispatchSemaphore!
  private let kTapBus = 0
  
  private var _outputQ = DispatchQueue(label: "Output", qos: .userInteractive, attributes: [.concurrent])
  private var _q = DispatchQueue(label: "Object", qos: .userInteractive, attributes: [.concurrent])
  
  // ----------------------------------------------------------------------------
  // MARK: - Private properties
  
  //    private var _encoder                      : OpaquePointer!
  
  //    private var _audioConverter               : AVAudioConverter!
  
  //    private var _encoderOutput                = [UInt8](repeating: 0, count: RemoteTxAudioStream.frameCount)
  
  //  private var _ringBuffer                   = RingBuffer()
  //    private var _bufferInput                  : AVAudioPCMBuffer!
  //    private var _bufferOutput                 : AVAudioPCMBuffer!
  
  //    private var _producerIndex                : Int64 = 0
  //
  //
  //    private let kConverterOutputFormat        = AVAudioFormat(commonFormat: .pcmFormatFloat32,
  //                                                              sampleRate: RemoteTxAudioStream.sampleRate,
  //                                                              channels: AVAudioChannelCount(RemoteTxAudioStream.channelCount),
  //                                                              interleaved: RemoteTxAudioStream.isInterleaved)!
  //    private let kConverterOutputFrameCount    = Int(RemoteTxAudioStream.sampleRate / 10)
  //    private let kRingBufferSlots              = 3
  
  // ----------------------------------------------------------------------------
  // MARK: - Initialization
  
  public init(_ delegate: AudioStreamHandler) {
    _delegate = delegate
    super.init()
    
    setupConversion()
    createTapInputBlock()
  }
  
  public func start() {
    // get the default input device
    let device = AudioHelper.inputDevices.filter { $0.isDefault }.first!
    
    // start Opus Tx Audio
    _engine = AVAudioEngine()
    clearBuffers()
    
    // try to set it as the input device for the engine
    if setInputDevice(device.id) {
      log("OpusEncoder: started", .info, #function, #file, #line)
      
      // start capture using this input device
      startInput(device)
      
    } else {
      log("OpusEncoder: FAILED to start, Device = \(device.name!)", .warning, #function, #file, #line)
      
      _engine?.inputNode.removeTap(onBus: kTapBus)
      _engine?.stop()
      _engine = nil
    }
  }
  
  public func stop() {
    log("OpusEncoder: stopped", .info, #function, #file, #line)
    
    _engine?.inputNode.removeTap(onBus: kTapBus)
    _engine?.stop()
    _engine = nil
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Private methods
  
  /// Capture data, convert it and place it in the ring buffer
  ///
  private func startInput(_ device: AHAudioDevice) {
    
    // get the input device's ASBD & derive the AVAudioFormat from it
    var asbd = device.asbd!
    let inputFormat = AVAudioFormat(streamDescription: &asbd)!
    
    // the Tap format is whatever the input node's output produces
    let tapFormat = _engine!.inputNode.outputFormat(forBus: kTapBus)
    
    // calculate a buffer size for 100 milliseconds of audio at the Tap
    //    NOTE: installTap header file says "Supported range is [100, 400] ms."
    _tapBufferSize = AVAudioFrameCount(tapFormat.sampleRate/10)
    
    // TODO: remove these in release version
    Swift.print("Input  device  = \(device.name!), ID = \(device.id)")
    Swift.print("Input  format  = \(inputFormat)")
    Swift.print("Tap    format  = \(tapFormat)")
    
    // Input converter: Tap format -> PCM Float32, 24_000, 2 channel, interleaved
    _inputConverter = AVAudioConverter(from: tapFormat, to: AVAudioFormat(streamDescription: &OpusEncoder.encoderInputASBD)!)
    
    // clear the buffers
    clearBuffers()
    
    // start a thread to empty the ring buffer
    _bufferSemaphore = DispatchSemaphore(value: 0)
    _outputActive = true
    startOutput()
    
    // setup the Tap callback to populate the ring buffer
    _engine!.inputNode.installTap(onBus: kTapBus, bufferSize: _tapBufferSize, format: tapFormat, block: _tapInputBlock)
    
    // prepare & start the engine
    _engine!.prepare()
    do {
      try _engine!.start()
    } catch {
      fatalError("OpusEncode: failed to start AVAudioEngine")
    }
  }
  /// Start a thread to empty the ring buffer
  ///
  private func startOutput() {
    _outputQ.async { [unowned self] in
      
      // start at the beginning of the ring buffer
      var frameNumber: Int64 = 0
      
      while self._outputActive {
        
        // wait for the data
        self._bufferSemaphore.wait()
        
        // process 240 frames per iteration
        for _ in 0..<10 {
          
          // TODO:
          
          //                    let fetchError = self._ringBuffer!.fetch(self._bufferOutput.mutableAudioBufferList,
          //                                                             nFrame: UInt32(RemoteTxAudioStream.frameCount),
          //                                                             frameNumnber: frameNumber)
          //                    if fetchError != 0 { Swift.print("Fetch error = \(String(describing: fetchError))") }
          //
          //                    // ------------------ ENCODE ------------------
          //
          //                    // perform Opus encoding
          //                    let encodedFrames = opus_encode_float(self._encoder,                            // an encoder
          //                                                          self._bufferOutput.floatChannelData![0],  // source (interleaved .pcmFloat32)
          //                                                          Int32(RemoteTxAudioStream.frameCount),    // source, frames per channel
          //                                                          &self._encoderOutput,                     // destination (Opus-encoded bytes)
          //                                                          Int32(RemoteTxAudioStream.frameCount))    // destination, max size (bytes)
          //                    // check for encode errors
          //                    if encodedFrames < 0 { Swift.print("Encoder error - " + String(cString: opus_strerror(encodedFrames))) }
          //
          //                    // send the encoded audio to the Radio
          //                    self._delegate?.sendTxAudio(buffer: self._encoderOutput, samples: Int(encodedFrames))
          //
          //                    // bump the frame number
          //                    frameNumber += Int64( RemoteTxAudioStream.frameCount )
        }
      }
    }
  }
  
  /// Set the input device for the engine
  /// - Parameter id:             an AudioDeviceID
  /// - Returns:                  true if successful
  ///
  private func setInputDevice(_ id: AudioDeviceID) -> Bool {
    // get the underlying AudioUnit
    let audioUnit = _engine!.inputNode.audioUnit!
    
    // set the new device as the input device
    var inputDeviceID = id
    let error = AudioUnitSetProperty(audioUnit,
                                     kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global,
                                     0,
                                     &inputDeviceID,
                                     UInt32(MemoryLayout<AudioDeviceID>.size))
    // success if no errors
    return error == noErr
  }
  
  /// Setup the converter and required buffers
  ///
  private func setupConversion() {
    // Opus converter: PCM Float32, 2 channel, interleaved -> Opus compressed, 2 channel
    _opusConverter = AVAudioConverter(from: AVAudioFormat(streamDescription: &OpusEncoder.encoderInputASBD)!,
                                      to: AVAudioFormat(streamDescription: &OpusEncoder.encoderOutputASBD)!)
    
    // create the Ring buffer (actual size will be adjusted to fit virtual memory page size)
    guard _TPCircularBufferInit( &_ringBuffer, UInt32(OpusEncoder.ringBufferSize), MemoryLayout<TPCircularBuffer>.stride ) else { fatalError("Ring Buffer not created") }
    
    // input to the ring buffer
    _ringInputBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(streamDescription: &OpusEncoder.encoderInputASBD)!, frameCapacity: UInt32(OpusEncoder.frameCount))!
    
    // output from the Opus encoder
    _encoderOutputBuffer = AVAudioCompressedBuffer(format: AVAudioFormat(streamDescription: &OpusEncoder.encoderOutputASBD)!, packetCapacity: 1, maximumPacketSize: OpusEncoder.frameCount)
    
  }
  
  /// Create a block to process the Tap data
  ///
  private func createTapInputBlock() {
    
    _tapInputBlock = { [unowned self] (inputBuffer, _) in
      
      // setup the Converter callback (assumes no errors)
      var error: NSError?
      self._inputConverter.convert(to: self._ringInputBuffer, error: &error, withInputFrom: { (_, outStatus) -> AVAudioBuffer? in
        
        // signal we have the needed amount of data
        outStatus.pointee = AVAudioConverterInputStatus.haveData
        
        // return the data to be converted
        return inputBuffer
      })
      
      // copy the frame's buffer to the Ring buffer & make it available
      TPCircularBufferCopyAudioBufferList(&_ringBuffer, &_ringInputBuffer.mutableAudioBufferList.pointee, nil, UInt32(OpusEncoder.frameCount), &OpusEncoder.encoderInputASBD)
      
      // signal the availability of data for the Output thread
      self._bufferSemaphore.signal()
    }
  }
  
  /// Clear all buffers
  ///
  private func clearBuffers() {
    
    // clear the buffers
    memset(_ringInputBuffer.floatChannelData![0], 0, Int(_ringInputBuffer.frameLength) * MemoryLayout<Float>.size * OpusEncoder.channelCount)
    memset(_encoderOutputBuffer.data, 0, Int(_encoderOutputBuffer.byteCapacity))
  }
}
