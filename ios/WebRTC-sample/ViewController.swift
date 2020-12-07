//
//  ViewController.swift
//  WebRTC-sample
//
//  Created by Kouki Saito on 2020/12/04.
//

import UIKit
import FirebaseFirestore
import WebRTC

class ViewController: UIViewController {

    @IBOutlet weak var createButton: UIBarButtonItem!
    @IBOutlet weak var joinButton: UIBarButtonItem!
    @IBOutlet weak var localVideoView: UIView!
    @IBOutlet weak var remoteVideoView: UIView!

    var webRTCClient: WebRTCClient!

    override func viewDidLoad() {
        super.viewDidLoad()

        webRTCClient = WebRTCClient()

        #if arch(arm64)
            // Using metal (arm64 only)
            let localRenderer = RTCMTLVideoView(frame: self.localVideoView?.frame ?? CGRect.zero)
            let remoteRenderer = RTCMTLVideoView(frame: self.view.frame)
            localRenderer.videoContentMode = .scaleAspectFill
            remoteRenderer.videoContentMode = .scaleAspectFill
        #else
            // Using OpenGLES for the rest
            let localRenderer = RTCEAGLVideoView(frame: self.localVideoView?.frame ?? CGRect.zero)
            let remoteRenderer = RTCEAGLVideoView(frame: self.view.frame)
        #endif

        webRTCClient.startCaptureLocalVideo(renderer: localRenderer)
        webRTCClient.renderRemoteVideo(to: remoteRenderer)

        add(view: localRenderer, container: localVideoView)
        add(view: remoteRenderer, container: remoteVideoView)
    }

    private func add(view: UIView, container: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        ])
    }

    // MARK: - caller
    @IBAction func createRoom(_ sender: UIBarButtonItem) {
        createButton.isEnabled = false
        joinButton.isEnabled = false
        let db = Firestore.firestore()
        let roomRef = db.collection("rooms").document()

        let callerCandidatesCollection = roomRef.collection("callerCandidates");
        webRTCClient.gotCandidate = { candidate in
            callerCandidatesCollection.addDocument(data: candidate.data)
        }

        roomRef.collection("calleeCandidates").addSnapshotListener { [weak self] (snapshot, _) in
            if let snapshot = snapshot {
                for change in snapshot.documentChanges {
                    if change.type == .added {
                        let data = change.document.data()

                        print("Got new remote ICE candidate: \(data)")
                        guard let candidate = RTCIceCandidate.from(data: data) else { return }
                        self?.webRTCClient.gotIceCandidate(candidate: candidate)
                    }
                }
            }
        }

        webRTCClient.offer() { [weak self] offer in
            print("Created offer: \(offer)")
            roomRef.setData([
                "offer": [
                    "type": "offer",
                    "sdp": offer.sdp,
                ]
            ])

            let roomId = roomRef.documentID;
            print("New room created with SDP offer. Room ID: \(roomId)");
            DispatchQueue.main.sync {
                let alert = UIAlertController(title: "Room ID", message: roomId, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Copy to Clipboard", style: .default, handler: { _ in
                    UIPasteboard.general.string = roomId
                }))
                self?.present(alert, animated: true, completion: nil)
            }

            roomRef.addSnapshotListener { [weak self] (snapshot, error) in
                print(error ?? "")
                guard let answer = RTCSessionDescription.from(answer: snapshot?.data()) else { return }
                self?.webRTCClient.gotAnswer(answer: answer)
            }
        }
    }

    // MARK: - callee
    @IBAction func joinRoom(_ sender: UIBarButtonItem) {
        createButton.isEnabled = false
        joinButton.isEnabled = false

        let alert = UIAlertController(title: "Input room ID", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Room ID"
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { [weak self] _ in
            let roomId = alert.textFields![0].text!
            self?.joinRoom(byId: roomId)
        }))
        present(alert, animated: true, completion: nil)
    }

    private func joinRoom(byId id: String) {
        let db = Firestore.firestore()
        let roomRef = db.collection("rooms").document(id)
        roomRef.getDocument { [weak self] (roomSnapshot, _) in
            guard let roomSnapshot = roomSnapshot else { return }
            print("Got room:", roomSnapshot.exists)

            if roomSnapshot.exists {
                let calleeCandidatesCollection = roomRef.collection("calleeCandidates")
                self?.webRTCClient.gotCandidate = { candidate in
                    calleeCandidatesCollection.addDocument(data: candidate.data)
                }
                roomRef.collection("callerCandidates").addSnapshotListener { [weak self] (snapshot, _) in
                    if let snapshot = snapshot {
                        for change in snapshot.documentChanges {
                            if change.type == .added {
                                let data = change.document.data()

                                print("Got new remote ICE candidate: \(data)")
                                guard let candidate = RTCIceCandidate.from(data: data) else { return }
                                self?.webRTCClient.gotIceCandidate(candidate: candidate)
                            }
                        }
                    }
                }

                guard let offer = RTCSessionDescription.from(offer: roomSnapshot.data()) else { return }
                print("Got offer: \(offer)")
                self?.webRTCClient.answer(offer: offer, completion: { answer in
                    roomRef.updateData([
                        "answer": [
                            "type": answer.type.firebaseType,
                            "sdp": answer.sdp
                        ]
                    ])
                })
            }
        }
    }
}

class WebRTCClient: NSObject {
    private let configuration: RTCConfiguration = {
        let configuration = RTCConfiguration()
        configuration.iceServers = [
            RTCIceServer(urlStrings: [
                "stun:stun1.l.google.com:19302", "stun:stun2.l.google.com:19302"
            ])
        ]
        configuration.iceCandidatePoolSize = 10
        configuration.sdpSemantics = .unifiedPlan
        return configuration
    }()

    private let factory: RTCPeerConnectionFactory = {
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
    private let videoSource: RTCVideoSource
    private let localVideoTrack: RTCVideoTrack

    private var peerConnection: RTCPeerConnection?

    private var videoCapturer: RTCVideoCapturer?
    private var remoteVideoTrack: RTCVideoTrack?

    public var gotCandidate: ((RTCIceCandidate) -> Void)?

    override init() {
        videoSource = factory.videoSource()
        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video1")
        super.init()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
        peerConnection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self)
        peerConnection?.add(localVideoTrack, streamIds: ["stream"])
        remoteVideoTrack = peerConnection?.transceivers.first { $0.mediaType == .video }?.receiver.track as? RTCVideoTrack
    }

    func offer(completion: @escaping (RTCSessionDescription) -> Void) {
        let constrains = RTCMediaConstraints(mandatoryConstraints: [
            kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
        ],
                                             optionalConstraints: nil)
        peerConnection?.offer(for: constrains, completionHandler: { [weak self] (offer, error) in
            print(error ?? "")
            guard let offer = offer else {
                return
            }

            self?.peerConnection?.setLocalDescription(offer, completionHandler: { (error) in
                completion(offer)
            })
        })
    }

    func answer(offer: RTCSessionDescription, completion: @escaping (RTCSessionDescription) -> Void) {
        peerConnection?.setRemoteDescription(offer, completionHandler: { [weak self] (error) in
            print(error ?? "")
            let constrains = RTCMediaConstraints(mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
            ],
                                                 optionalConstraints: nil)
            self?.peerConnection?.answer(for: constrains, completionHandler: { [weak self] (answer, error) in
                print(error ?? "")
                guard let answer = answer else { return }
                self?.peerConnection?.setLocalDescription(answer, completionHandler: { (error) in
                    print(error ?? "")
                    completion(answer)
                })
            })
        })
    }

    func gotAnswer(answer: RTCSessionDescription) {
        peerConnection?.setRemoteDescription(answer, completionHandler: { (error) in
            print(error ?? "")
        })
    }

    func gotIceCandidate(candidate: RTCIceCandidate) {
        peerConnection?.add(candidate)
    }

    func startCaptureLocalVideo(renderer: RTCVideoRenderer) {
        videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
        guard let capturer = videoCapturer as? RTCCameraVideoCapturer else {
            print("Error: Camera not found")
            return
        }

        guard let frontCamera = (RTCCameraVideoCapturer.captureDevices().first { $0.position == .front }),
              let format = RTCCameraVideoCapturer.supportedFormats(for: frontCamera).max(by: {
                CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
              }),
              let fps = format.videoSupportedFrameRateRanges.max(by: {
                $0.maxFrameRate < $1.maxFrameRate
              }) else {
            return
        }

        capturer.startCapture(with: frontCamera,
                              format: format,
                              fps: Int(fps.maxFrameRate))

        localVideoTrack.add(renderer)
    }

    func renderRemoteVideo(to renderer: RTCVideoRenderer) {
        remoteVideoTrack?.add(renderer)
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("peerConnectionShouldNegotiate")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print(stateChanged)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print(stream)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print(stream)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print(candidate)
        gotCandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print(candidates)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print(dataChannel)
    }
}

extension RTCSdpType {
    var firebaseType: String {
        switch self {
        case .answer:
            return "answer"
        case .offer:
            return "offer"
        case .prAnswer:
            return "pranswer"
        @unknown default:
            fatalError()
        }
    }

    public init?(firebaseType: String) {
        switch firebaseType {
        case "answer":
            self = .answer
        case "offer":
            self = .offer
        case "pranswer":
            self = .prAnswer
        default:
            return nil
        }
    }
}

extension RTCIceCandidate {
    var data: [String: Any] {
        [
            "candidate": sdp,
            "sdpMLineIndex": sdpMLineIndex,
            "sdpMid": sdpMid ?? "",
        ]
    }
}

extension RTCSessionDescription {
    static func from(answer: [String: Any]?) -> RTCSessionDescription? {
        guard let data = answer?["answer"] as? [String: Any] else { return nil }
        guard let firebaseTypeString = data["type"] as? String,
              let firebaseType = RTCSdpType(firebaseType: firebaseTypeString),
              let sdp = data["sdp"] as? String,
              firebaseType == .answer else { return nil }
        let answer = RTCSessionDescription(type: firebaseType, sdp: sdp)
        return answer
    }

    static func from(offer: [String: Any]?) -> RTCSessionDescription? {
        guard let data = offer?["offer"] as? [String: Any] else { return nil }
        guard let firebaseTypeString = data["type"] as? String,
              let firebaseType = RTCSdpType(firebaseType: firebaseTypeString),
              let sdp = data["sdp"] as? String,
              firebaseType == .offer else { return nil }
        let offer = RTCSessionDescription(type: firebaseType, sdp: sdp)
        return offer
    }
}

extension RTCIceCandidate {
    static func from(data: [String: Any]?) -> RTCIceCandidate? {
        guard let sdp = data?["candidate"] as? String,
              let sdpMLineIndex = data?["sdpMLineIndex"] as? Int32,
              let sdpMid = data?["sdpMid"] as? String else { return nil }

        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        return candidate
    }
}
