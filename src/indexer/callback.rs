use std::{fmt::Debug, future::Future, pin::Pin, sync::Arc};

use oura::{
  model::Event,
  pipelining::{BootstrapResult, SinkProvider, StageReceiver},
  utils::Utils,
};
use strum_macros::Display;
use tokio::runtime::Runtime;
use tracing::{event, span, Instrument, Level};

use super::{
  error::ErrorPolicyProvider,
  retry::{perform_with_retry, RetryPolicy},
};

/// This is a custom made sink for Oura. Based on a callback function.
/// The idea is similar to a webhook, but instead of calling a web endpoint - we call a function directly.
pub(crate) struct Callback<E> {
  // https://stackoverflow.com/questions/77589520/lifetime-of-struct-with-field-of-type-boxed-async-callback-must-outlive-static
  pub(crate) f:
    Arc<dyn Fn(Event) -> Pin<Box<dyn Future<Output = Result<(), E>> + Send + Sync>> + Send + Sync>,
  pub(crate) retry_policy: RetryPolicy,
  pub(crate) utils: Arc<Utils>,
}

impl<E: Debug + ErrorPolicyProvider + 'static> SinkProvider for Callback<E> {
  fn bootstrap(&self, input: StageReceiver) -> BootstrapResult {
    let span = span!(Level::INFO, "Callback::bootstrap");
    let _enter = span.enter();

    let retry_policy = self.retry_policy;
    let utils = self.utils.clone();

    let f = Arc::clone(&self.f);
    let handle = span!(Level::DEBUG, "SpawningThread").in_scope(|| {
      std::thread::spawn(move || {
        let span = span!(Level::DEBUG, "EventHandlingThread");
        let _enter = span.enter();

        // Running async function sycnhronously within another thread.
        let rt = Runtime::new().unwrap();
        rt.block_on(handle_event(input, |ev: Event| f(ev), &retry_policy, utils))
          .or_else(|err| {
            event!(Level::ERROR, label=%Events::EventHandlerFailure, ?err);
            Err(err)
          })
          .expect("request loop failed");
      })
    });

    Ok(handle)
  }
}

// Handle a sequence of events transmitted at once.
async fn handle_event<
  E: Debug + ErrorPolicyProvider + 'static,
  R: Future<Output = Result<(), E>>,
>(
  input: StageReceiver,
  callback_fn: impl Fn(Event) -> R,
  retry_policy: &RetryPolicy,
  utils: Arc<Utils>,
) -> Result<(), E> {
  let span = span!(Level::INFO, "handle_event");
  let _enter = span.enter();
  for chain_event in input.iter() {
    let span = span!(
      Level::INFO,
      "HandlingBlock",
      block_no = &chain_event.context.block_number.unwrap(),
      block_hash = &chain_event.context.block_hash.clone().unwrap(),
      slot_no = &chain_event.context.slot.unwrap(),
    );
    // Have to clone twice here to please the borrow checker...
    perform_with_retry(|| callback_fn(chain_event.clone()), retry_policy)
      .instrument(span)
      .await
      // Notify progress to the pipeline.
      .map(|_| utils.track_sink_progress(&chain_event))?;
    // ^ This will exit the loop if an error is returned.
    // After all, `perform_with_retry` will only return error if all other options,
    // based on `ErrorPolicy`, were exhausted.
  }
  // All chain events in this sequence have been handled.
  Ok(())
}

#[derive(Display)]
pub enum Events {
  EventHandlerFailure,
}
