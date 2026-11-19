//! Axo-owned chrome only. Terminal cells/fonts remain Ghostty-rendered; this does
//! not change the desktop theme or style arbitrary Ghostty/application widgets.
use gtk4::{gdk, prelude::*};

pub fn install() -> Result<(), String> {
    let display = gdk::Display::default().ok_or("no GTK display")?;
    let css = gtk4::CssProvider::new();
    let problem = std::rc::Rc::new(std::cell::RefCell::new(None));
    let parsed = css.connect_parsing_error({
        let problem = problem.clone();
        move |_, _, error| {
            *problem.borrow_mut() = Some(error.to_string());
        }
    });
    css.load_from_string(CSS);
    css.disconnect(parsed);
    if let Some(error) = problem.borrow_mut().take() {
        return Err(format!("Axo stylesheet: {error}"));
    }
    gtk4::style_context_add_provider_for_display(
        &display,
        &css,
        gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
    );
    Ok(())
}

/// Use widget layout for insets: container CSS padding can displace AT-SPI
/// bounds from the rendered controls in the supported GTK build.
pub fn inset(widget: &impl IsA<gtk4::Widget>, vertical: i32, horizontal: i32) {
    widget.set_margin_top(vertical);
    widget.set_margin_bottom(vertical);
    widget.set_margin_start(horizontal);
    widget.set_margin_end(horizontal);
}

/// Embedded marks, not theme-dependent substitutes or remotely loaded images.
pub fn brand_icon(bytes: &'static [u8]) -> gtk4::Image {
    let icon = gtk4::gio::BytesIcon::new(&gtk4::glib::Bytes::from_static(bytes));
    let image = gtk4::Image::from_gicon(&icon);
    image.set_pixel_size(16);
    image
}

pub fn icon_button(icon: &str, label: &str) -> gtk4::Button {
    let button = gtk4::Button::from_icon_name(icon);
    button.set_tooltip_text(Some(label));
    button.update_property(&[
        gtk4::accessible::Property::Label(label),
        gtk4::accessible::Property::Description(label),
    ]);
    button.add_css_class("axo-icon-button");
    button
}

/// Keep CSD resize/move behavior and the platform's window controls, but put
/// them in the sidebar so the terminal reaches the top edge, like Axo on Mac.
pub fn sidebar_titlebar(
    window: &impl IsA<gtk4::Window>,
    title: Option<&str>,
) -> gtk4::WindowHandle {
    let empty = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    empty.add_css_class("axo-hidden-titlebar");
    window.set_titlebar(Some(&empty));
    let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    row.add_css_class("axo-drag-strip");
    inset(&row, 2, 8);
    // Honour both halves of gtk-decoration-layout (including left-side controls).
    row.append(&gtk4::WindowControls::new(gtk4::PackType::Start));
    let caption = gtk4::Label::new(title);
    caption.add_css_class("axo-window-title");
    caption.set_hexpand(true);
    caption.set_xalign(0.0);
    caption.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    row.append(&caption);
    row.append(&gtk4::WindowControls::new(gtk4::PackType::End));
    let handle = gtk4::WindowHandle::new();
    handle.set_child(Some(&row));
    handle
}

// Reference: the running Mac workbench and grouped settings, not its
// terminal's application-generated ANSI colors. Linux keeps native CSD controls.
const CSS: &str = r#"
window.axo-window {
  background: #222829; color: #dedfe0; font-family: sans-serif; font-size: 13px;
}
.axo-window .axo-hidden-titlebar { min-height: 0; padding: 0; margin: 0; border: none; background: transparent; }
.axo-window .axo-sidebar { background: #202020; }
.axo-window .axo-drag-strip { min-height: 24px; }
.axo-window .axo-window-title { font-size: 13px; font-weight: 600; color: #d4d6d7; }
.axo-window .axo-host-caption { font-size: 12px; font-weight: 600; color: #b2b2b2; }
.axo-window windowcontrols { border-spacing: 2px; }
.axo-window windowcontrols button {
  min-width: 22px; min-height: 24px; padding: 0; margin: 0;
  background: transparent; border: none; box-shadow: none; border-radius: 5px; color: #b8babb;
}
.axo-window windowcontrols button:hover { background: #3d4142; color: #fff; }
.axo-window windowcontrols button.close:hover { background: #7c343e; }
.axo-window .axo-section-caption { font-size: 10px; font-weight: 600; color: #777b7c; }
.axo-window .axo-session-list { background: transparent; }
.axo-window .axo-session-list > row, .axo-window .axo-settings-nav row {
  padding: 0; margin: 0; min-height: 22px; border-radius: 4px; background: transparent;
  box-shadow: none; border: none; color: #dedfe0;
}
.axo-window .axo-session-list > row { font-size: 12px; }
.axo-window .axo-session-list > row:hover { background: #2b2b2b; }
.axo-window .axo-session-list > row:selected { background: #303a4b; color: #fff; }
.axo-window .axo-status { font-size: 11px; color: #a0a3a4; }
.axo-window .axo-icon-button { min-width: 24px; min-height: 24px; padding: 2px; }
.axo-window .axo-session-status { font-size: 9px; }
.axo-window .axo-ready { color: #38d16b; }
.axo-window .axo-working { color: #6aa7f4; }
.axo-window .axo-attention { color: #f4bc56; }
.axo-window .axo-unavailable { color: #85898b; }
.axo-window button {
  background: #383e40; color: #e2e3e4; border: 1px solid transparent;
  border-radius: 6px; box-shadow: none; text-shadow: none; min-height: 24px; padding: 2px 12px;
}
.axo-window button:hover { background: #454b4d; }
.axo-window button:active { background: #505759; }
.axo-window button:disabled { color: #85898a; background: #343a3c; opacity: 1; }
.axo-window button:focus-visible, .axo-window entry:focus-within {
  outline: 2px solid #91a8ef; outline-offset: 1px;
}
.axo-window .axo-icon-button { background: transparent; border-color: transparent; }
.axo-window .axo-icon-button:hover { background: #3b4143; }
.axo-window separator { background: #353b3d; min-width: 1px; min-height: 1px; }
.axo-window paned > separator { background: #353b3d; min-width: 1px; min-height: 1px; }
.axo-window .axo-settings-nav { background: #2d3436; }
.axo-window .axo-settings-nav list { background: transparent; }
.axo-window .axo-settings-nav row { min-height: 32px; border-radius: 8px; margin: 0 0 1px; }
.axo-window .axo-settings-nav row:hover { background: #393f41; }
.axo-window .axo-settings-nav row:selected { background: #494b4c; color: #f0f0f0; }
.axo-window .axo-settings-body { background: #222829; }
.axo-window .axo-settings-page { background: transparent; }
.axo-window .axo-section-title { font-size: 13px; font-weight: 600; color: #dedfe0; }
.axo-window .axo-setting-card { background: #2a3032; border: none; border-radius: 10px; }
.axo-window .axo-field-help { color: #a3a6a7; font-size: 11px; }
.axo-window entry { background: transparent; color: #dedfe0; border: 1px solid transparent; border-radius: 4px; min-height: 28px; box-shadow: none; padding: 0 4px; }
.axo-window entry:hover { background: #303739; }
.axo-window entry:focus-within { background: #222829; }
.axo-window entry:disabled { color: #919698; }
.axo-window .axo-feedback { font-size: 11px; color: #a3a6a7; }
.axo-window scrollbar { background: transparent; }
.axo-window scrollbar slider { min-width: 5px; min-height: 5px; border-radius: 5px; background: #52585a; }
"#;
