//! Sending a command to a running service through the file queue and waiting for its result:
//! what a dashboard or a shortcut does.

use std::time::Duration;

use jiff::Timestamp;
use tempo_core::store::{Command, CommandQueue, CommandResult};
use tempo_core::time::seconds;

/// Enqueues `command` and waits for the service's result. `None` means nobody answered
/// within `timeout`; the command is withdrawn first, so it can't be applied after the caller
/// has reported that it wasn't.
pub async fn send(
    queue: &CommandQueue,
    command: Command,
    timeout: Duration,
    poll_every: Duration,
) -> Option<CommandResult> {
    let id = queue.enqueue(command, Timestamp::now()).ok()?;
    let deadline = tokio::time::Instant::now() + timeout;
    while tokio::time::Instant::now() < deadline {
        tokio::time::sleep(poll_every).await;
        if let Some(result) = queue.result(id) {
            return Some(result);
        }
    }
    let _ = queue.cancel(id);
    queue.purge(seconds(3600), Timestamp::now());
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn send_returns_the_result_once_completed() {
        let dir = tempfile::tempdir().unwrap();
        let queue = CommandQueue::new(dir.path());
        let executor = {
            let queue = queue.clone();
            tokio::spawn(async move {
                loop {
                    let pending = queue.pending(Timestamp::now());
                    if pending.is_empty() {
                        tokio::time::sleep(Duration::from_millis(20)).await;
                        continue;
                    }
                    for envelope in pending {
                        queue
                            .complete(envelope.id, true, Some("Done.".into()), Timestamp::now())
                            .unwrap();
                    }
                    break;
                }
            })
        };
        let result = send(
            &queue,
            Command::SetPaused(true),
            Duration::from_secs(5),
            Duration::from_millis(50),
        )
        .await;
        executor.await.unwrap();
        assert_eq!(result.as_ref().map(|r| r.success), Some(true));
        assert_eq!(result.and_then(|r| r.message).as_deref(), Some("Done."));
        assert!(queue.pending(Timestamp::now()).is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn send_times_out_and_withdraws_the_command() {
        let dir = tempfile::tempdir().unwrap();
        let queue = CommandQueue::new(dir.path());
        let result = send(
            &queue,
            Command::CaptureSittingPreset,
            Duration::from_millis(300),
            Duration::from_millis(50),
        )
        .await;
        assert!(result.is_none());
        assert!(queue.pending(Timestamp::now()).is_empty());
    }
}
