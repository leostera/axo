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
pub fn sidebar_titlebar(window: &gtk4::ApplicationWindow) -> gtk4::WindowHandle {
    let empty = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    empty.add_css_class("axo-hidden-titlebar");
    window.set_titlebar(Some(&empty));
    let row = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    row.add_css_class("axo-drag-strip");
    row.set_margin_top(5);
    row.set_margin_bottom(5);
    row.set_margin_start(12);
    row.set_margin_end(8);
    // Honour both halves of gtk-decoration-layout (including left-side controls).
    row.append(&gtk4::WindowControls::new(gtk4::PackType::Start));
    let brand = gtk4::Label::new(Some("axo"));
    brand.add_css_class("axo-brand");
    brand.set_hexpand(true);
    brand.set_xalign(0.0);
    row.append(&brand);
    row.append(&gtk4::WindowControls::new(gtk4::PackType::End));
    let handle = gtk4::WindowHandle::new();
    handle.set_child(Some(&row));
    handle
}

const CSS: &str = r#"
window.axo-window {
  background: #111318; color: #dce0e7; font-family: sans-serif; font-size: 13px;
}
.axo-window .axo-hidden-titlebar { min-height: 0; padding: 0; margin: 0; border: none; background: #111318; }
.axo-window .axo-sidebar { background: #1b1d23; }
.axo-window .axo-drag-strip { min-height: 28px; }
.axo-window .axo-brand { font-size: 16px; font-weight: 700; color: #eff1f5; letter-spacing: -0.5px; }
.axo-window windowcontrols { border-spacing: 2px; }
.axo-window windowcontrols button {
  min-width: 22px; min-height: 24px; padding: 0; margin: 0;
  background: transparent; border: none; box-shadow: none; border-radius: 5px; color: #a4a9b4;
}
.axo-window windowcontrols button:hover { background: #353842; color: #fff; }
.axo-window windowcontrols button.close:hover { background: #7c343e; }
.axo-window .axo-section-caption { font-size: 10px; font-weight: 600; color: #9299a6; }
.axo-window .axo-session-list { background: transparent; }
.axo-window .axo-session-list > row, .axo-window .axo-settings-nav row {
  padding: 0; margin: 1px 0; min-height: 26px; border-radius: 6px; background: transparent;
  box-shadow: none; border: 1px solid transparent; color: #b9bfca;
}
.axo-window .axo-session-list > row:hover, .axo-window .axo-settings-nav row:hover { background: #262930; }
.axo-window .axo-session-list > row:selected, .axo-window .axo-settings-nav row:selected {
  background: #303542; color: #f1f3f7; border-color: #3b4353;
}
.axo-window .axo-sidebar-footer { border-top: 1px solid #2a2d35; }
.axo-window .axo-status { font-size: 11px; color: #989fac; }
.axo-window .axo-icon-button { min-width: 28px; min-height: 28px; padding: 2px; }
.axo-window button {
  background: #2a2e37; color: #dce0e7; border: 1px solid #3a404c;
  border-radius: 6px; box-shadow: none; text-shadow: none; min-height: 28px; padding: 2px 12px;
}
.axo-window button:hover { background: #353b48; }
.axo-window button:active { background: #414a5d; }
.axo-window button:disabled { color: #717885; background: #22262e; border-color: #2d323c; }
.axo-window button:focus-visible, .axo-window entry:focus-within {
  outline: 2px solid #91a8ef; outline-offset: 1px;
}
.axo-window .axo-icon-button { background: transparent; border-color: transparent; }
.axo-window .axo-icon-button:hover { background: #303542; }
.axo-window separator { background: #292d35; min-width: 1px; min-height: 1px; }
.axo-window paned > separator { background: #2c313b; min-width: 1px; min-height: 1px; }
.axo-window .axo-pane-heading { font-size: 10px; color: #808997; background: #111318; }
.axo-window .axo-pane:focus-within .axo-pane-heading { color: #c2cee7; }
.axo-window headerbar {
  min-height: 34px; padding: 2px 8px; background: #1b1d23; color: #c2c8d2;
  box-shadow: none; border-bottom: 1px solid #292d35;
}
.axo-window .axo-settings-nav { background: #1b1d23; }
.axo-window .axo-settings-nav row { padding: 4px 8px; }
.axo-window .axo-settings-body { background: #15171d; }
.axo-window .axo-settings-page { background: transparent; }
.axo-window .axo-page-title { font-size: 19px; font-weight: 600; color: #eef0f5; }
.axo-window .axo-page-description { color: #969eac; font-size: 12px; }
.axo-window .axo-setting-card { background: #1e2129; border: 1px solid #303540; border-radius: 8px; }
.axo-window .axo-field-title { font-weight: 600; color: #d9dee8; }
.axo-window .axo-field-help { color: #969eac; font-size: 11px; }
.axo-window entry { background: #14171d; color: #e0e5ed; border: 1px solid #3b4350; border-radius: 5px; min-height: 30px; box-shadow: none; padding: 0 9px; }
.axo-window entry:disabled { color: #7d8592; }
.axo-window .axo-command { font-family: monospace; font-size: 12px; }
.axo-window .axo-settings-footer { border-top: 1px solid #292d35; background: #191c22; }
.axo-window .axo-feedback { font-size: 11px; color: #a8b1c0; }
.axo-window scrollbar { background: transparent; }
.axo-window scrollbar slider { min-width: 5px; min-height: 5px; border-radius: 5px; background: #454c5a; }
"#;
