import AppKit

@MainActor
protocol ShutdownParticipant: AnyObject {
    func prepareForShutdown(completion: @escaping (Bool) -> Void)
    func resumeAfterCancelledShutdown()
}

/// Holds every live window until its collection and exports have settled.
@MainActor
final class ApplicationShutdownCoordinator {
    static let shared = ApplicationShutdownCoordinator()
    private(set) var isTerminating = false
    private var participants: [ObjectIdentifier: any ShutdownParticipant] = [:]
    private var pendingUnregister: Set<ObjectIdentifier> = []
    private var prepared: Set<ObjectIdentifier> = []
    private var outstanding: Set<ObjectIdentifier> = []
    private var reply: ((Bool) -> Void)?
    private var allSaved = true
    private var generation = UUID()

    func register(_ participant: any ShutdownParticipant) {
        let id = ObjectIdentifier(participant)
        guard participants[id] == nil else { return }
        participants[id] = participant
        if isTerminating { prepare(participant, generation: generation) }
    }

    func unregister(_ participant: any ShutdownParticipant) {
        let id = ObjectIdentifier(participant)
        // Pending callbacks own participants until the entire Quit attempt settles.
        if isTerminating {
            pendingUnregister.insert(id)
        } else {
            participants.removeValue(forKey: id)
        }
    }

    func requestTermination(reply: @escaping (Bool) -> Void) {
        guard !isTerminating else { return }
        isTerminating = true
        allSaved = true
        prepared.removeAll()
        generation = UUID()
        self.reply = reply
        let token = generation
        // AppKit must receive .terminateLater before even an empty batch replies.
        DispatchQueue.main.async { [self] in
            guard token == generation else { return }
            let current = participants.values.filter { !prepared.contains(ObjectIdentifier($0)) }
            outstanding.formUnion(current.map(ObjectIdentifier.init))
            for participant in current { prepare(participant, generation: token) }
            finishIfReady(generation: token)
        }
    }

    private func prepare(_ participant: any ShutdownParticipant, generation token: UUID) {
        let id = ObjectIdentifier(participant)
        guard prepared.insert(id).inserted else { return }
        outstanding.insert(id)
        participant.prepareForShutdown { [self] saved in
            guard isTerminating, token == generation, outstanding.remove(id) != nil else { return }
            allSaved = allSaved && saved
            finishIfReady(generation: token)
        }
    }

    private func finishIfReady(generation token: UUID) {
        guard outstanding.isEmpty else { return }
        DispatchQueue.main.async { [self] in
            guard isTerminating, token == generation, outstanding.isEmpty, let reply else { return }
            self.reply = nil
            let saved = allSaved
            for id in pendingUnregister { participants.removeValue(forKey: id) }
            pendingUnregister.removeAll()
            if !saved {
                isTerminating = false
                for participant in participants.values { participant.resumeAfterCancelledShutdown() }
            }
            reply(saved)
        }
    }
}

@MainActor
final class QcicadaApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationShutdownCoordinator.shared.requestTermination { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
}
