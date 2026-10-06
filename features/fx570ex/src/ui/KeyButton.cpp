#include "KeyButton.h"

#include <QPainter>
#include <QPaintEvent>

namespace fx {

namespace {
const QColor kDarkKey(0x17, 0x17, 0x19);
const QColor kDarkKeyDown(0x33, 0x33, 0x37);
const QColor kLightKey(0xea, 0xea, 0xe6);
const QColor kLightKeyDown(0xc4, 0xc4, 0xbe);
const QColor kAccent(0x2f, 0x6d, 0xf6);
const QColor kAccentDown(0x1d, 0x4f, 0xc4);
const QColor kSmallKey(0x4f, 0x4f, 0x54);
const QColor kShiftText(0xf0, 0xb4, 0x29);
const QColor kAlphaText(0xe8, 0x61, 0x7d);
const QColor kAltText(0x5a, 0xa9, 0xf0);
const QColor kHighlight(0xf0, 0xb4, 0x29);
} // namespace

KeyButton::KeyButton(QString id, QString main, KeyStyle style, QWidget *parent)
    : QAbstractButton(parent), m_id(std::move(id)), m_style(style)
{
    setText(std::move(main));
    setCursor(Qt::PointingHandCursor);
    setFocusPolicy(Qt::NoFocus);
    setMinimumSize(44, 34);
}

QSize KeyButton::sizeHint() const
{
    return m_style == KeyStyle::Small ? QSize(48, 30) : QSize(58, 42);
}

void KeyButton::setHighlighted(bool on)
{
    if (m_highlighted == on)
        return;
    m_highlighted = on;
    update();
}

void KeyButton::paintEvent(QPaintEvent *)
{
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, true);

    const bool down = isDown();
    const bool hasLegend = !m_shift.isEmpty() || !m_alpha.isEmpty() || !m_alt.isEmpty();
    const qreal legendH = hasLegend ? 13.0 : 0.0;

    // The printed legends sit on the case, above the key itself.
    if (hasLegend) {
        QFont lf = font();
        lf.setPixelSize(9);
        lf.setBold(true);
        p.setFont(lf);
        const QFontMetricsF lfm(lf);
        const qreal y = lfm.ascent() + 0.5;
        if (!m_shift.isEmpty()) {
            p.setPen(kShiftText);
            p.drawText(QPointF(2.0, y), m_shift);
        }
        if (!m_alpha.isEmpty()) {
            p.setPen(kAlphaText);
            p.drawText(QPointF(width() - lfm.horizontalAdvance(m_alpha) - 2.0, y), m_alpha);
        }
        if (!m_alt.isEmpty()) {
            p.setPen(kAltText);
            const qreal x = width() - lfm.horizontalAdvance(m_alt) - 2.0;
            p.drawText(QPointF(m_alpha.isEmpty() ? x : (width() / 2.0 + 2.0), y), m_alt);
        }
    }

    QRectF face(1.0, legendH, width() - 2.0, height() - legendH - 1.0);

    QColor bg, fg;
    switch (m_style) {
    case KeyStyle::Dark:
        bg = down ? kDarkKeyDown : kDarkKey;
        fg = Qt::white;
        break;
    case KeyStyle::Light:
        bg = down ? kLightKeyDown : kLightKey;
        fg = QColor(0x2a, 0x22, 0x1e);
        break;
    case KeyStyle::Accent:
        bg = down ? kAccentDown : kAccent;
        fg = Qt::white;
        break;
    case KeyStyle::Small:
        bg = down ? kDarkKeyDown : kSmallKey;
        fg = Qt::white;
        break;
    }

    const qreal radius = (m_style == KeyStyle::Small) ? face.height() / 2.0 : 7.0;
    p.setPen(m_highlighted ? QPen(kHighlight, 2) : QPen(QColor(0, 0, 0, 40), 1));
    p.setBrush(bg);
    p.drawRoundedRect(face.adjusted(0.5, 0.5, -0.5, -0.5), radius, radius);

    QFont mf = font();
    mf.setPixelSize(m_style == KeyStyle::Light ? 17 : 14);
    mf.setBold(true);
    p.setFont(mf);
    p.setPen(fg);
    p.drawText(face, Qt::AlignCenter, text());
}

} // namespace fx
