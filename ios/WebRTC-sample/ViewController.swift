//
//  ViewController.swift
//  WebRTC-sample
//
//  Created by Kouki Saito on 2020/12/04.
//

import UIKit
import FirebaseFirestore

class ViewController: UIViewController {

    @IBOutlet weak var createButton: UIBarButtonItem!
    @IBOutlet weak var joinButton: UIBarButtonItem!
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
    }

    @IBAction func createRoom(_ sender: UIBarButtonItem) {
        createButton.isEnabled = false
        joinButton.isEnabled = false
        // TODO: Initialize RTCPeerConnection
        let db = Firestore.firestore()
        let roomRef = db.collection("rooms").document()
        let callerCandidatesCollection = roomRef.collection("callerCandidates")

        // TODO: Modify to use real RTCPeerConnection's candidate
        callerCandidatesCollection.addDocument(data: ["candidate": "candidate1"])

        roomRef.collection("calleeCandidates").addSnapshotListener { (snapshot, _) in
            if let snapshot = snapshot {
                for change in snapshot.documentChanges {
                    if change.type == .added {
                        let data = change.document.data()
                        print("Got new remote ICE candidate: \(data)")
                        // TODO: peerConnection.addIceCandidate
                    }
                }
            }
        }

        // TODO: alert room ID
    }
    
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
        roomRef.getDocument { (roomSnapshot, _) in
            guard let roomSnapshot = roomSnapshot else { return }
            print("Got room:", roomSnapshot.exists)

            if roomSnapshot.exists {
                print("Create PeerConnection with configuration: TODO: replace me for configuration")
                // TODO: create RTCPeerConnection and config

                // TODO: get icecandidate
                // let calleeCandidatesCollection = roomRef.collection("calleeCandidates")
                // calleeCandidatesCollection.addDocument(["candidate": "candidate"])

                let offer = roomSnapshot.data()?["offer"]
                print("Got offer: \(offer ?? "")")

                // TODO: create answer
                // TODO: addAnswer to roomRef

                roomRef.collection("callerCandidates").addSnapshotListener { (snapshot, error) in
                    guard let snapshot = snapshot else { return }
                    for change in snapshot.documentChanges {
                        if change.type == .added {
                            let data = change.document.data()
                            print("Got new remote ICE candidate: \(data)")
                            // TODO: peerConnection.addIceCandidate)
                        }
                    }
                }
            }
        }
    }
}
