#if SORELLO_KEYBOARD_DICTATION
import Darwin
import os

/// The keyboard process's memory, content-free (ARCHITECTURE.md, "In-keyboard dictation (experiment)", Record): the
/// footprint jetsam counts (`phys_footprint`), the process's lifetime high-water mark of it (`ledger_phys_footprint_peak`)
/// and what iOS still allows it (`os_proc_available_memory`), in MB. The simulator has no memory limit, so there the
/// memory left is unknown.
enum KeyboardMemory {
    static func sample() -> KeyboardMemorySample {
        var sample = KeyboardMemorySample()
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            sample.footprintMB = Double(info.phys_footprint) / 1_048_576
            sample.peakMB = Double(info.ledger_phys_footprint_peak) / 1_048_576
        }
        #if !targetEnvironment(simulator)
        sample.availableMB = Double(os_proc_available_memory()) / 1_048_576
        #endif
        return sample
    }
}
#endif
