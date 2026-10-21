//! The window's surface coming and going (Android): `NativeActivity` destroys the native window
//! when the app goes to the background and often when the screen changes shape (a fold or
//! unfold, a rotation, split screen), and creates a new one, of whatever size, when it comes back.
//! The renderer keeps its device, pipelines and textures through that; only the swapchain goes.
use super::Game;
use winit::event_loop::ActiveEventLoop;

impl Game<'_> {
    /// `ApplicationHandler::suspended`: the native window is about to be destroyed, so the surface
    /// has to be dropped before this returns. Nothing happens off Android, where it is never called.
    pub(super) fn surface_lost(&mut self) {
        if !cfg!(target_os = "android") {
            return;
        }
        log::info!("Horizon: the window's surface was destroyed");
        if let Some(renderer) = &mut self.renderer {
            renderer.suspend_surface();
        }
        // Android may end an app in the background without a word: what is unsaved goes to disk now,
        // asynchronously, as an autosave does.
        if self.title.is_none()
            && self.player.is_some()
            && self.integrated.is_none()
            && let Err(e) = self.save_game_with(false)
        {
            log::warn!("Horizon: could not save as the app went to the background: {e}");
        }
        // Fingers and keys that were down will never be released.
        self.keys.clear();
        self.physical_keys.clear();
        self.left = false;
        self.right = false;
        self.touch_release();
    }

    /// `ApplicationHandler::resumed` with the window already made: a new surface of the window's
    /// size now.
    pub(super) fn surface_back(&mut self, event_loop: &ActiveEventLoop) {
        let Some(window) = self.window.clone() else {
            return;
        };
        let Some(renderer) = &mut self.renderer else {
            return;
        };
        if renderer.has_surface() {
            return;
        }
        let size = window.inner_size();
        match renderer.reattach_surface(size.width, size.height) {
            Ok(()) => log::info!(
                "Horizon: the window's surface is back ({}x{})",
                size.width,
                size.height
            ),
            Err(e) => {
                log::error!("Horizon: could not attach the window's surface again: {e}");
                self.error = Some(e);
                event_loop.exit();
            }
        }
    }
}
