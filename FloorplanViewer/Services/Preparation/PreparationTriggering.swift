import Foundation

/// The narrow face of the preparation engine that UI models depend on — keeps the actor out of
/// view-model tests (a spy suffices) and views away from engine internals.
nonisolated protocol PreparationTriggering: Sendable {
    func prepare(projectID: String) async
    func retryNow(projectID: String) async
    func prepareAll() async
}

extension PackagePreparationCoordinator: PreparationTriggering {}
