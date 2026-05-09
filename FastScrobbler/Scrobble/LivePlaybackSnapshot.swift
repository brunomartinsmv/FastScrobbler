import Foundation
import MediaPlayer

struct LivePlaybackSnapshot: Equatable {
    let track: Track
    let startedAt: Date
    let expectedEndAt: Date
    let playbackState: MPMusicPlaybackState
    let isActivelyTracking: Bool
}
