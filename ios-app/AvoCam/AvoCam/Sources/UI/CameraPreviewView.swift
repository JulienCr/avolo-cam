//
//  CameraPreviewView.swift
//  AvoCam
//
//  Camera preview view using AVCaptureVideoPreviewLayer
//

import SwiftUI
import AVFoundation
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let captureSession: AVCaptureSession?

    func makeUIView(context: Context) -> PreviewUIView {
        return PreviewUIView(captureSession: captureSession)
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.updateSession(captureSession)
    }
}

class PreviewUIView: UIView {
    private var captureSession: AVCaptureSession?

    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }

    init(captureSession: AVCaptureSession?) {
        self.captureSession = captureSession
        super.init(frame: .zero)

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.session = captureSession

        // Update preview orientation to match device orientation
        updateOrientation()

        // Observe device orientation changes to update preview orientation
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func deviceOrientationDidChange() {
        // Update orientation when device rotates
        updateOrientation()
    }

    private func updateOrientation() {
        guard let connection = previewLayer.connection, connection.isVideoOrientationSupported else {
            return
        }

        // Map device orientation to video orientation
        let deviceOrientation = UIDevice.current.orientation
        let videoOrientation: AVCaptureVideoOrientation

        switch deviceOrientation {
        case .portrait:
            videoOrientation = .portrait
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        case .landscapeLeft:
            // Note: Device landscape left means video orientation landscape right
            videoOrientation = .landscapeRight
        case .landscapeRight:
            // Note: Device landscape right means video orientation landscape left
            videoOrientation = .landscapeLeft
        default:
            // For unknown/face-up/face-down, keep current orientation
            return
        }

        connection.videoOrientation = videoOrientation
    }

    func updateSession(_ session: AVCaptureSession?) {
        if captureSession !== session {
            captureSession = session
            previewLayer.session = session

            // Ensure orientation is updated when session changes
            updateOrientation()
        }
    }
}
