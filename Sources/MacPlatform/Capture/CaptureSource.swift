@preconcurrency import AVFoundation
import DictationCore

// The seam between the capture's lifecycle and AVFoundation. `MicrophoneCapture` decides when to open and close
// and what the samples become; a `CaptureSourceOpening` only opens a device and hands over buffers. Tests put a
// fake here and feed synthetic buffers.

/// Hears what a running source produces, on the source's own delivery queue.
protocol CaptureSourceSink: AnyObject, Sendable {
    func received(_ buffer: AVAudioPCMBuffer)
    /// The device went away, or the system interrupted the session.
    func interrupted(_ reason: CaptureInterruption)
    /// The session reported another runtime error.
    func failed()
}

/// Opens a microphone. Called only on the capture's lifecycle queue.
protocol CaptureSourceOpening: Sendable {
    /// Opens the device `request` names, or if it names none or that device is gone, the system default or the
    /// microphone that stands in for a Bluetooth default (`MicrophoneChoice`), and returns once it is running. Blocks while it starts. Throws `CaptureFailure`. Must never cause a permission prompt.
    func open(_ request: CaptureRequest, sink: any CaptureSourceSink) throws(CaptureFailure) -> any CaptureSourceRunning
}

/// A running source. Called only on the capture's lifecycle queue.
protocol CaptureSourceRunning: AnyObject, Sendable {
    /// Stops and releases the device. Blocks until it has, and until no sink call is in flight; none follows.
    func stop()
}

/// `AVCaptureSession` with an audio data output on a private serial queue (ARCHITECTURE.md, section 6, "Audio
/// capture"). The audio engine's input tap is not used: with some Bluetooth and aggregate devices it delivers no
/// buffers.
struct AVCaptureSource: CaptureSourceOpening {
    func open(_ request: CaptureRequest, sink: any CaptureSourceSink) throws(CaptureFailure) -> any CaptureSourceRunning {
        // Opening a device without access would show the system's prompt; access is asked for elsewhere, when the
        // user first dictates.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw .permissionDenied }
        // The choice is made here, once, from the devices present now; the capture keeps the device it opens.
        let choice = MicrophoneChoice.resolve(AudioInputDevices().current(), chosenID: request.deviceID,
                                              avoidBluetooth: request.avoidBluetooth)
        let device = MicrophoneChoice.device(
            for: choice,
            find: { AVCaptureDevice(uniqueID: $0).flatMap { $0.isConnected && $0.hasMediaType(.audio) ? $0 : nil } },
            systemDefault: { AVCaptureDevice.default(for: .audio) })
        guard let device else { throw choice == nil ? .noInputDevice : .deviceUnavailable }
        if choice?.replacing != nil { Diagnostics.record("capture.standIn") }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw .deviceUnavailable }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw .deviceUnavailable
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        let running = RunningCaptureSession(session: session, device: device, output: output, sink: sink)
        session.startRunning()
        guard session.isRunning else {
            running.stop()
            throw .deviceUnavailable
        }
        return running
    }
}

/// Safe: every method is called on the capture's lifecycle queue only, one at a time; the delegate and the
/// notification observers reach the sink, which is `Sendable`, and nothing here.
final class RunningCaptureSession: CaptureSourceRunning, @unchecked Sendable {
    private let session: AVCaptureSession
    private let output: AVCaptureAudioDataOutput
    private let delivery = DispatchQueue(label: "sorello.capture.delivery", qos: .userInteractive)
    private let delegate: SampleBufferDelegate
    private var observers: [any NSObjectProtocol] = []
    private var stopped = false

    init(session: AVCaptureSession, device: AVCaptureDevice, output: AVCaptureAudioDataOutput,
         sink: any CaptureSourceSink) {
        self.session = session
        self.output = output
        delegate = SampleBufferDelegate(sink: sink)
        output.setSampleBufferDelegate(delegate, queue: delivery)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device,
                                            queue: nil) { _ in sink.interrupted(.deviceRemoved) })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session,
                                            queue: nil) { _ in sink.interrupted(.sessionInterrupted) })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session,
                                            queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            if error?.code == .deviceWasDisconnected {
                sink.interrupted(.deviceRemoved)
            } else {
                sink.failed()
            }
        })
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
        // A buffer already handed to the delivery queue finishes before this returns.
        delivery.sync {}
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
    }
}

private final class SampleBufferDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    let sink: any CaptureSourceSink

    init(sink: any CaptureSourceSink) {
        self.sink = sink
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if let buffer = AVAudioPCMBuffer.copying(sampleBuffer) {
            sink.received(buffer)
        } else {
            sink.failed()
        }
    }
}
