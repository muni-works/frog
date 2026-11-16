# A thread just stopped

**The short answer:** send a message. The thread, its changes and its history are all still there, and Frog picks up from your message.

## What you'll see

A turn that ends without finishing says why, under the last step.

<!-- only: web -->
- **"The reply hit the length limit before it finished."** The model ran out of room for its answer. Continue asks it to go on.
- **"Frog stopped because it was repeating itself."** The model made the same call over and over.
- **"Frog stopped here because you denied a step."** A step you said no to ended the turn.
- **"Frog stopped: a step it needs was denied."** Frog tried again a step that was already denied, so it stopped instead of asking twice.
- **An error with Try again:** the model's provider returned an error.
- **"You're out of cloud credits":** see Frog Cloud.
<!-- end -->

<!-- only: mac, terminal -->
- **The length limit:** the model ran out of room for its answer.
- **Repeating itself:** the model made the same call over and over.
- **A denied step:** a step you said no to ended the turn.
- **An error:** the model's provider returned an error.
- **Out of credit:** Frog Cloud credit ran out; see Frog Cloud.
<!-- end -->

A model that returns an empty reply is asked once more. A second empty reply ends the turn with the line "The model returned an empty reply twice, so the turn ended without an answer. Send a message to continue."

<!-- only: web -->
On the web that line shows only while the turn runs, so the thread can look finished with no answer. Send a message to go on.
<!-- end -->

## What to do

Send a message: "keep going", or a plainer version of the task. If the model keeps stopping, pick another one in the model menu and send again.

## The setting

There's no setting for this. A turn has no step limit unless `FROG_MAX_STEPS` sets one.
