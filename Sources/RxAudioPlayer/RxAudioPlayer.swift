//
//  OpusPlayer.swift
//  UtilityFeatures/RxAudioPlayer
//
//  Created by Douglas Adams on 2/12/16.
//  Copyright © 2016 Douglas Adams. All rights reserved.
//

import Accelerate
import AudioToolbox
import AVFoundation
import Foundation

import RingBuffer
import SharedModel
import XCGWrapper

//  DATA FLOW (COMPRESSED)
//
//  Stream Handler  ->  Opus Decoder   ->   Ring Buffer   ->  OutputUnit    -> Output device
//
//                  [UInt8]            [Float]            [Float]           set by hardware
//
//                  opus               pcmFloat32         pcmFloat32
//                  24_000             24_000             24_000
//                  2 channels         2 channels         2 channels
//                                     interleaved        interleaved

//  DATA FLOW (NOT COMPRESSED)
//
//  Stream Handler  ->   Ring Buffer   ->  OutputUnit    -> Output device
//
//                  [Float]            [Float]           set by hardware
//
//                  pcmFloat32         pcmFloat32
//                  24_000             24_000
//                  2 channels         2 channels
//                  interleaved        interleaved

public final class RxAudioPlayer: NSObject, RxAudioHandler {
  // ----------------------------------------------------------------------------
  // MARK: - Public properties
  
  public var streamId: UInt32?

  // ----------------------------------------------------------------------------
  // MARK: - Static properties
  
  private static let channelCount = 2
  private static let frameCountOpus = 240
  private static let frameCountUncompressed = 128
  private static let pcmElementSize = MemoryLayout<Float>.size    // Bytes
  private static let sampleRate: Double = 24_000

  private static let ringBufferCapacity = 20      // number of AudioBufferLists in the Ring buffer
  private static let ringBufferOverage  = 2_048   // allowance for Ring buffer metadata (in Bytes)
  // uses the larger frameCountOpus (vs frameCountUncompressed), size is somewhat arbitrary
  private static let ringBufferSize = (frameCountOpus * pcmElementSize * channelCount * ringBufferCapacity) + ringBufferOverage
  private static var ringBuffer = TPCircularBuffer()

  // Compressed Opus, UInt8, 2 channel
  private static var opusASBD = AudioStreamBasicDescription(mSampleRate: sampleRate,
                                                            mFormatID: kAudioFormatOpus,
                                                            mFormatFlags: 0,
                                                            mBytesPerPacket: 0,
                                                            mFramesPerPacket: UInt32(frameCountOpus),
                                                            mBytesPerFrame: 0,
                                                            mChannelsPerFrame: UInt32(channelCount),
                                                            mBitsPerChannel: 0,
                                                            mReserved: 0)
  
  // PCM, Float32, 2 channel, interleaved
  private static var opusPcmASBD = AudioStreamBasicDescription(mSampleRate: sampleRate,
                                                               mFormatID: kAudioFormatLinearPCM,
                                                               mFormatFlags: kAudioFormatFlagIsFloat,
                                                               mBytesPerPacket: UInt32(pcmElementSize * channelCount),
                                                               mFramesPerPacket: 1,
                                                               mBytesPerFrame: UInt32(pcmElementSize * channelCount),
                                                               mChannelsPerFrame: UInt32(channelCount),
                                                               mBitsPerChannel: UInt32(pcmElementSize * 8),
                                                               mReserved: 0)
  
  // PCM, BigEndian, Float32, 2 channel, interleaved
  private static var pcmASBD = AudioStreamBasicDescription(mSampleRate: sampleRate,
                                                           mFormatID: kAudioFormatLinearPCM,
                                                           mFormatFlags: kAudioFormatFlagIsFloat,
                                                           mBytesPerPacket: UInt32(pcmElementSize * channelCount),
                                                           mFramesPerPacket: 1,
                                                           mBytesPerFrame: UInt32(pcmElementSize * channelCount),
                                                           mChannelsPerFrame: UInt32(channelCount),
                                                           mBitsPerChannel: UInt32(pcmElementSize * 8),
                                                           mReserved: 0)
  
  // ----------------------------------------------------------------------------
  // MARK: - Private properties
  
  // convert from Opus -> PCM Float32, 2 channel, interleaved
  private var _converter = AVAudioConverter(from: AVAudioFormat(streamDescription: &RxAudioPlayer.opusASBD)!,
                                            to: AVAudioFormat(streamDescription: &RxAudioPlayer.opusPcmASBD)!)
  private var _opusBuffer = AVAudioCompressedBuffer()
  private var _outputUnit: AudioUnit?
  private var _opusPcmASBD = RxAudioPlayer.opusPcmASBD
  private var _opusPcmBuffer = AVAudioPCMBuffer()
  private var _pcmBuffer = AVAudioPCMBuffer()
  private var _sampleRate: Double = RxAudioPlayer.sampleRate
  private var _swappedPayload = [UInt32]()

  // ----------------------------------------------------------------------------
  // MARK: - RenderProc definition
  
  /// AudioUnit Render proc
  ///   retrieves PCM Float32 interleaved data from the ring buffer -> Output unit
  ///
  private let renderProc: AURenderCallback = { (inRefCon: UnsafeMutableRawPointer, _, _, _, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>? ) in
    guard let ioData = ioData else { fatalError("ioData is null") }
    
    // retrieve the requested number of frames
    var lengthInFrames = inNumberFrames
    TPCircularBufferDequeueBufferListFrames(&RxAudioPlayer.ringBuffer, &lengthInFrames, ioData, nil, &RxAudioPlayer.opusPcmASBD)

    // assumes no error
    return noErr
  }

  // ----------------------------------------------------------------------------
  // MARK: - Initialization
  
  public init(volume: Float, isCompressed: Bool = true) {   // FIXME: What to do with volume?

    if isCompressed {
      // create an AVAudioCompressedBuffer for the received opus data
      _opusBuffer = AVAudioCompressedBuffer(format: AVAudioFormat(streamDescription: &RxAudioPlayer.opusASBD)!, packetCapacity: 1, maximumPacketSize: RxAudioPlayer.frameCountOpus)

      // create an AVAudioPCMBuffer buffer for pcm data output from the converter: PCM, Float32, interleaved
      _opusPcmBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(streamDescription: &RxAudioPlayer.opusPcmASBD)!, frameCapacity: UInt32(RxAudioPlayer.frameCountOpus))!
      _opusPcmBuffer.frameLength = _opusPcmBuffer.frameCapacity

    } else {
      // create a temporary data array
      _swappedPayload = [UInt32](repeating: 0, count: RxAudioPlayer.frameCountUncompressed * RxAudioPlayer.channelCount)

      // create an AVAudioPCMBuffer buffer for pcm data
      _pcmBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(streamDescription: &RxAudioPlayer.pcmASBD)!, frameCapacity: UInt32(RxAudioPlayer.frameCountUncompressed))!
      _pcmBuffer.frameLength = _pcmBuffer.frameCapacity
    }
    // create the Ring buffer (actual size will be adjusted to fit virtual memory page size)
    guard _TPCircularBufferInit( &RxAudioPlayer.ringBuffer, UInt32(RxAudioPlayer.ringBufferSize), MemoryLayout<TPCircularBuffer>.stride ) else { fatalError("Ring Buffer not created") }

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
    AudioUnitSetProperty(outputUnit,
                         kAudioUnitProperty_SampleRate,
                         kAudioUnitScope_Input,
                         0,
                         &_sampleRate,
                         UInt32(MemoryLayout<Float64>.size))
    
    // set the output unit's Input stream format (PCM Float32 interleaved)
    AudioUnitSetProperty(outputUnit,
                         kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Input,
                         0,
                         &_opusPcmASBD,
                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Public methods
  
  public func start(_ streamId: UInt32) {
    self.streamId = streamId
    
    TPCircularBufferClear(&RxAudioPlayer.ringBuffer)
    
    let availableFrames = TPCircularBufferGetAvailableSpace(&RxAudioPlayer.ringBuffer, &RxAudioPlayer.opusPcmASBD)
    log("RxAudioPlayer: STARTED, frames = \(availableFrames)", .debug, #function, #file, #line)
    
    // register render callback
    var renderCallback: AURenderCallbackStruct
    renderCallback = AURenderCallbackStruct(inputProc: renderProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())

    AudioUnitSetProperty(_outputUnit!,
                         kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Input,
                         0,
                         &renderCallback,
                         UInt32(MemoryLayout.size(ofValue: renderCallback)))
    guard AudioUnitInitialize(_outputUnit!) == noErr else { fatalError("Output unit not initialized") }
    
    guard AudioOutputUnitStart(_outputUnit!) == noErr else { fatalError("Output unit failed to start") }
  }
  
  public func stop() {
    guard let outputUnit = _outputUnit else { return }
    
    AudioOutputUnitStop(outputUnit)
    
    let availableFrames = TPCircularBufferGetAvailableSpace(&RxAudioPlayer.ringBuffer, &RxAudioPlayer.opusPcmASBD)
    log("RxAudioPlayer: STOPPED, frames = \(availableFrames) ", .debug, #function, #file, #line)

    AudioUnitUninitialize(outputUnit)
    AudioComponentInstanceDispose(outputUnit)
  }

  // ----------------------------------------------------------------------------
  // MARK: - Stream Handler protocol methods
  
  /// Process the UDP Stream Data for RemoteRxAudioStream streams
    public func rxAudioHandler(payload: [UInt8], compressed: Bool) {
      let totalBytes = payload.count

    if compressed {
      // OPUS Compressed RemoteRxAudio
      
      if totalBytes != 0 {
        // Valid packet: copy the data and save the count
        memcpy(_opusBuffer.data, payload, totalBytes)
        _opusBuffer.byteLength = UInt32(totalBytes)
        _opusBuffer.packetCount = AVAudioPacketCount(1)
        _opusBuffer.packetDescriptions![0].mDataByteSize = _opusBuffer.byteLength
      } else {
        // Missed packet:
        _opusBuffer.byteLength = UInt32(totalBytes)
        _opusBuffer.packetCount = AVAudioPacketCount(1)
        _opusBuffer.packetDescriptions![0].mDataByteSize = _opusBuffer.byteLength
      }
      // Convert from the opusBuffer (Opus) to the pcmBuffer (PCM Float32, interleaved)
      var error: NSError?
      _ = _converter!.convert(to: _opusPcmBuffer, error: &error, withInputFrom: { (_, outputStatus) -> AVAudioBuffer? in
        outputStatus.pointee = .haveData
        return self._opusBuffer
      })
      
      // check for decode errors
      if error != nil { fatalError("Opus conversion error: \(error!)") }
      
      // add the pcmBuffer to the Ring buffer & make it available
      TPCircularBufferCopyAudioBufferList(&RxAudioPlayer.ringBuffer, &_opusPcmBuffer.mutableAudioBufferList.pointee, nil, UInt32(RxAudioPlayer.frameCountOpus), &RxAudioPlayer.opusPcmASBD)
      
    } else {
      // UN-Compressed RemoteRxAudio
      
      payload.withUnsafeBytes { (samplesPtr) in
        // get a pointer to the 32-bit Float samples
        let uint32Ptr = samplesPtr.bindMemory(to: UInt32.self)
        
        // Swap the byte ordering of the Float32 samples
        for i in 0..<totalBytes / 4 {
          _swappedPayload[i] = CFSwapInt32BigToHost(uint32Ptr[i])
        }
        // copy the byte-swapped data to the pcmBuffer
        memcpy(_pcmBuffer.floatChannelData![0], _swappedPayload, totalBytes)
      }
      // add the pcmBuffer to the Ring buffer & make it available
      TPCircularBufferCopyAudioBufferList(&RxAudioPlayer.ringBuffer, &_pcmBuffer.mutableAudioBufferList.pointee, nil, UInt32(RxAudioPlayer.frameCountUncompressed), &RxAudioPlayer.opusPcmASBD)
    }
  }
}
