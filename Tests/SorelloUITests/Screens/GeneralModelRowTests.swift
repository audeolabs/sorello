import Testing
@testable import SorelloUI

/// The General screen says where the model runs on this Mac (ARCHITECTURE.md, section 5), and how long preparing
/// takes there: minutes the first time on the Neural Engine, a moment every time on the processor.
struct GeneralModelRowTests {
    @Test func readySaysWhereTheModelRuns() {
        #expect(ModelRow.detail(.ready, on: .neuralEngine) == "On this Mac, on the Neural Engine.")
        #expect(ModelRow.detail(.ready, on: .processor) == "On this Mac, on its processor.")
    }

    @Test func preparingSaysHowLongItTakesThere() {
        #expect(ModelRow.detail(.preparing, on: .neuralEngine)
                == "The first time on a Mac can take a few minutes. You can dictate meanwhile.")
        #expect(ModelRow.detail(.preparing, on: .processor)
                == "Loading takes a moment each time the app opens. You can dictate meanwhile.")
    }

    @Test(arguments: [ModelProblem.damaged, .couldNotLoad])
    func aFailureExplainsItselfWhereverTheModelRuns(problem: ModelProblem) {
        #expect(ModelRow.detail(.failed(problem), on: .neuralEngine) == problem.explanation)
        #expect(ModelRow.detail(.failed(problem), on: .processor) == problem.explanation)
    }

    /// Without the model, the row says how large the download is and where from, how much has arrived, why it
    /// stopped in one of four sentences, or that there is no model for this Mac (ARCHITECTURE.md, section 8).
    @Test func aModelNotOnThisMacSaysWhereItsDownloadStands() {
        let size: Int64 = 138_084_519
        #expect(ModelRow.detail(.notDownloaded(.notStarted(size: size)), on: .neuralEngine)
                == "Not downloaded yet. 138 MB, from Hugging Face.")
        #expect(ModelRow.detail(.notDownloaded(.downloading(received: 62_400_000, size: size)), on: .processor)
                == "62 MB of 138 MB")
        #expect(ModelRow.detail(.notDownloaded(.unavailable), on: .neuralEngine)
                == "There is no speech model for this Mac yet.")
        let reasons: [(ModelDownloadProblem, String)] = [
            (.connection, "The connection dropped. Try again when you’re online."),
            (.server, "Hugging Face didn’t provide the model. Try again later."),
            (.check, "The download didn’t pass its check. Try again."),
            (.disk, "There isn’t enough free space. The model needs 138 MB."),
        ]
        for (problem, sentence) in reasons {
            #expect(ModelRow.detail(.notDownloaded(.failed(problem, size: size)), on: .neuralEngine) == sentence)
        }
        #expect(ModelDownloadStatus.notStarted(size: size).offersDownload)
        #expect(ModelDownloadStatus.failed(.disk, size: size).offersDownload)
        #expect(!ModelDownloadStatus.downloading(received: 0, size: size).offersDownload)
        #expect(!ModelDownloadStatus.unavailable.offersDownload)
    }

    /// Sizes read as whole megabytes of 1,000,000 bytes, the same in every locale; what has arrived is never rounded
    /// up past what is there.
    @Test func sizesReadAsWholeMegabytes() {
        #expect(ModelSize.words(138_084_519) == "138 MB")
        #expect(ModelSize.words(1_500_000) == "2 MB")
        #expect(ModelSize.words(0) == "0 MB")
        #expect(ModelSize.progress(received: 0, of: 138_084_519) == "0 MB of 138 MB")
        #expect(ModelSize.progress(received: 999_999, of: 138_084_519) == "0 MB of 138 MB")
        #expect(ModelSize.progress(received: 62_999_999, of: 138_084_519) == "62 MB of 138 MB")
        #expect(ModelSize.progress(received: 138_084_519, of: 138_084_519) == "138 MB of 138 MB")
        #expect(ModelSize.progress(received: 1_999_999, of: 1_500_000) == "1 MB of 2 MB")
        #expect(ModelSize.fraction(received: 69_042_259, of: 138_084_519) > 0.49)
        #expect(ModelSize.fraction(received: 5, of: 0) == 0)
        #expect(ModelSize.fraction(received: 500, of: 100) == 1)
    }
}
