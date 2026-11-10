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

    @Test(arguments: [ModelProblem.missing, .damaged, .couldNotLoad])
    func aFailureExplainsItselfWhereverTheModelRuns(problem: ModelProblem) {
        #expect(ModelRow.detail(.failed(problem), on: .neuralEngine) == problem.explanation)
        #expect(ModelRow.detail(.failed(problem), on: .processor) == problem.explanation)
    }
}
