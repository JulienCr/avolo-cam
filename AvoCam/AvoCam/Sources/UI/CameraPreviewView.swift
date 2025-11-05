//
//  CameraPreviewView.swift
//  AvoCam
//
//  Camera preview view using AVCaptureVideoPreviewLayer
//

import SwiftUI
import AVFoundation

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

        // Lock preview orientation to portrait
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateSession(_ session: AVCaptureSession?) {
        if captureSession !== session {
            captureSession = session
            previewLayer.session = session

            // Ensure orientation is locked when session changes
            if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }
}
