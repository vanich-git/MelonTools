//! Kill-on-close Windows Job Object shared by every engine the app spawns.
//!
//! `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` is a kernel guarantee: when the last
//! handle to the job closes with the main process, every assigned process is
//! terminated. That covers a crash, a forced kill and the updater's exit, so a
//! zombie gateway or llama-server cannot keep a port or RAM after the app is
//! gone. A newly spawned engine fails closed if assignment is unavailable;
//! otherwise the app could promise crash cleanup it cannot actually guarantee.

#[cfg(windows)]
mod imp {
    use std::sync::OnceLock;
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE,
    };

    static JOB: OnceLock<Result<usize, String>> = OnceLock::new();

    fn handle() -> Result<HANDLE, String> {
        // Initialization must be serialized: racing CreateJobObject calls could
        // leak untracked job handles and silently assign engines to other jobs.
        JOB.get_or_init(|| unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
                return Err(std::io::Error::last_os_error().to_string());
            }
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const core::ffi::c_void,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            ) == 0
            {
                let error = std::io::Error::last_os_error().to_string();
                let _ = CloseHandle(job);
                return Err(error);
            }
            Ok(job as usize)
        })
        .as_ref()
        .map(|job| *job as HANDLE)
        .map_err(Clone::clone)
    }

    /// The caller must kill a just-spawned engine if containment fails.
    pub fn assign(pid: u32) -> Result<(), String> {
        let job = handle()?;
        unsafe {
            let process = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, pid);
            if process.is_null() {
                return Err(std::io::Error::last_os_error().to_string());
            }
            let result = if AssignProcessToJobObject(job, process) == 0 {
                Err(std::io::Error::last_os_error().to_string())
            } else {
                Ok(())
            };
            let _ = CloseHandle(process);
            result
        }
    }
}

#[cfg(not(windows))]
mod imp {
    #[allow(dead_code)]
    pub fn assign(_pid: u32) -> Result<(), String> {
        Ok(())
    }
}

pub use imp::assign;
