// In the build for older Macs a view follows a model as an ObservableObject, which is what an @Observable class is
// there (Sources/SystemCompat/Observation.swift). `@Bindable` keeps its name and its `$model.property` bindings. The
// usual build compiles none of this.
#if SORELLO_LEGACY
import SwiftUI

typealias Bindable = ObservedObject
#endif
