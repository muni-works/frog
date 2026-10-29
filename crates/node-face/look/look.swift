// look: where the person in front of the camera is, for node-face's eye contact (macOS).
//
//   swiftc -O look.swift -o look        # then node-face --look ./look (or LOOK_BIN)
//   look [--camera NAME]                 # NAME: a piece of the camera's name; default the built-in one
//
// One JSON line per analysed frame (~15 a second) on stdout:
//   {"faces":1,"x":-0.21,"y":0.08,"size":0.31}
// x, y: the largest face's centre, -1..1, in the face's own frame: +x is toward the person's right
// as they look at the screen (the camera image is mirrored for this), +y is down. size: the face's
// height over the frame's. With nobody there: {"faces":0}. On the head, the stereo camera will take
// this one's place behind the same line protocol.

import AVFoundation
import Foundation
import Vision

final class Look: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "look")
    var last = Date.distantPast

    func start(camera: String?) throws {
        let kinds: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .continuityCamera, .external]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: kinds, mediaType: .video, position: .unspecified).devices
        let device = camera.flatMap { c in found.first { $0.localizedName.localizedCaseInsensitiveContains(c) } }
            ?? found.first { $0.deviceType == .builtInWideAngleCamera }
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw NSError(domain: "look", code: 1, userInfo: [NSLocalizedDescriptionKey: "no camera"]) }
        FileHandle.standardError.write("look: \(device.localizedName)\n".data(using: .utf8)!)
        session.sessionPreset = .vga640x480
        session.addInput(try AVCaptureDeviceInput(device: device))
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(out)
        session.startRunning()
    }

    func captureOutput(_: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard Date().timeIntervalSince(last) > 1.0 / 15.0, let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        last = Date()
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: px, options: [:]).perform([req])
        let faces = req.results ?? []
        guard let f = faces.max(by: { $0.boundingBox.height < $1.boundingBox.height }) else {
            emit("{\"faces\":0}")
            return
        }
        let b = f.boundingBox // normalised, origin bottom-left, as the camera sees it
        let x = -(b.midX * 2 - 1) // mirror: the person's right is the camera's left
        let y = -(b.midY * 2 - 1)
        emit(String(format: "{\"faces\":%d,\"x\":%.3f,\"y\":%.3f,\"size\":%.3f}", faces.count, x, y, b.height))
    }

    func emit(_ s: String) {
        print(s)
        fflush(stdout)
    }
}

let args = CommandLine.arguments
let camera = args.firstIndex(of: "--camera").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
let look = Look()
AVCaptureDevice.requestAccess(for: .video) { ok in
    guard ok else {
        FileHandle.standardError.write("look: camera access denied\n".data(using: .utf8)!)
        exit(1)
    }
    do { try look.start(camera: camera) } catch {
        FileHandle.standardError.write("look: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}
RunLoop.main.run()
