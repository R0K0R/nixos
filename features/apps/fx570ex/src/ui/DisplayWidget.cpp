#include "DisplayWidget.h"
#include "NaturalRender.h"

#include <QFontDatabase>
#include <QPainter>
#include <QPaintEvent>
#include <QStringList>
#include <cmath>

namespace fx {

namespace {
const QColor kPanel(0xcf, 0xd8, 0xc8);
const QColor kPanelEdge(0xb4, 0xbd, 0xad);
const QColor kInk(30, 52, 90);
const QColor kInkFaint(30, 52, 90, 70);

constexpr qreal kMargin = 10.0;
constexpr qreal kStatusHeight = 16.0;

QFont displayFont()
{
    QFont f = QFontDatabase::systemFont(QFontDatabase::FixedFont);
    f.setStyleStrategy(QFont::PreferAntialias);
    f.setPixelSize(26);
    return f;
}
} // namespace

DisplayWidget::DisplayWidget(Engine *engine, QWidget *parent)
    : QWidget(parent), m_engine(engine)
{
    setMinimumHeight(170);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);

    m_blink.setInterval(500);
    connect(&m_blink, &QTimer::timeout, this, [this] {
        m_cursorOn = !m_cursorOn;
        update();
    });
    m_blink.start();

    connect(m_engine, &Engine::stateChanged, this, [this] {
        m_cursorOn = true;
        update();
    });
}

void DisplayWidget::setShiftActive(bool on)
{
    m_shift = on;
    update();
}

void DisplayWidget::setAlphaActive(bool on)
{
    m_alpha = on;
    update();
}

void DisplayWidget::setInsertMode(bool on)
{
    m_insert = on;
    update();
}

void DisplayWidget::resizeEvent(QResizeEvent *event)
{
    QWidget::resizeEvent(event);
    update();
}

void DisplayWidget::drawStatusBar(QPainter &p, const QRectF &r)
{
    QFont f = font();
    f.setPixelSize(11);
    f.setBold(true);
    p.setFont(f);

    struct Indicator {
        QString text;
        bool on;
    };
    const FormatOptions fmt = m_engine->formatOptions();
    const QVector<Indicator> items = {
        { QStringLiteral("S"), m_shift },
        { QStringLiteral("A"), m_alpha },
        { QStringLiteral("M"), m_engine->memoryActive() },
        { QStringLiteral("STO"), false },
        { QStringLiteral("D"), m_engine->angleUnit() == AngleUnit::Deg },
        { QStringLiteral("R"), m_engine->angleUnit() == AngleUnit::Rad },
        { QStringLiteral("G"), m_engine->angleUnit() == AngleUnit::Gra },
        { QStringLiteral("FIX"), fmt.format == DisplayFormat::Fix },
        { QStringLiteral("SCI"), fmt.format == DisplayFormat::Sci },
        { QStringLiteral("i"), m_engine->complexMode() },
        { QStringLiteral("INS"), m_insert },
    };

    qreal x = r.left();
    const QFontMetricsF fm(f);
    for (const Indicator &it : items) {
        if (!it.on)
            continue;
        p.setPen(kInk);
        p.drawText(QPointF(x, r.top() + fm.ascent()), it.text);
        x += fm.horizontalAdvance(it.text) + 5.0;
    }

    p.setPen(QPen(kInkFaint, 1));
    p.drawLine(QPointF(r.left(), r.bottom()), QPointF(r.right(), r.bottom()));
}

void DisplayWidget::drawEntry(QPainter &p, const QRectF &r)
{
    NaturalRender render(displayFont(), 26.0);
    render.setCursor(m_engine->cursorRow(), m_engine->cursorIndex());
    render.setShowCursor(true);
    render.resetCursorRect();

    const Node *root = m_engine->root();
    const Box box = render.measureRow(root, 0);

    // Keep the caret on screen by sliding the whole line horizontally.
    const qreal avail = r.width();
    QRectF probe;
    {
        QPainter measurePass;
        // A dry run: draw into a null painter only to learn the caret position.
        QPixmap scratch(1, 1);
        measurePass.begin(&scratch);
        measurePass.setPen(Qt::NoPen);
        render.draw(&measurePass, root, 0.0, box.ascent, 0);
        measurePass.end();
        probe = render.cursorRect();
    }
    if (probe.isNull()) {
        m_scrollX = 0.0;
    } else {
        if (probe.right() - m_scrollX > avail - 6.0)
            m_scrollX = probe.right() - avail + 6.0;
        if (probe.left() - m_scrollX < 0.0)
            m_scrollX = std::max(0.0, probe.left() - 4.0);
        if (box.width - m_scrollX < avail && box.width > avail)
            m_scrollX = box.width - avail;
        if (box.width <= avail)
            m_scrollX = 0.0;
    }

    p.save();
    p.setClipRect(r);
    p.setPen(kInk);
    const qreal baseline = r.top() + std::max(box.ascent, 20.0);
    render.resetCursorRect();
    render.draw(&p, root, r.left() - m_scrollX, baseline, 0);

    const QRectF caret = render.cursorRect();
    if (!caret.isNull() && m_cursorOn) {
        QColor c = kInk;
        p.fillRect(QRectF(caret.left(), caret.top(), m_insert ? 3.0 : 1.8, caret.height()), c);
    }
    p.restore();

    // Scroll arrows, like the LCD's left/right markers.
    p.setPen(kInk);
    QFont af = font();
    af.setPixelSize(12);
    p.setFont(af);
    if (m_scrollX > 0.5)
        p.drawText(QPointF(r.left() - 8.0, r.top() + 14.0), QStringLiteral("◀"));
    if (box.width - m_scrollX > avail + 0.5)
        p.drawText(QPointF(r.right() + 1.0, r.top() + 14.0), QStringLiteral("▶"));
}

void DisplayWidget::drawResult(QPainter &p, const QRectF &r)
{
    const QString text = m_engine->errorText().isEmpty() ? m_engine->resultText()
                                                         : m_engine->errorText();
    if (text.isEmpty())
        return;

    QFont f = displayFont();
    f.setPixelSize(30);
    QFontMetricsF fm(f);
    // Shrink long results rather than clipping them.
    int px = 30;
    while (px > 12 && QFontMetricsF(f).horizontalAdvance(text) > r.width()) {
        f.setPixelSize(--px);
    }
    fm = QFontMetricsF(f);

    p.setFont(f);
    p.setPen(kInk);

    // "x10^n" is rendered with a real superscript.
    const int marker = text.indexOf(QStringLiteral("×10^"));
    if (marker >= 0) {
        const QString head = text.left(marker) + QStringLiteral("×10");
        const QString expo = text.mid(marker + 4);
        QFont sf = f;
        sf.setPixelSize(std::max(9, static_cast<int>(px * 0.62)));
        const QFontMetricsF sfm(sf);
        const qreal total = fm.horizontalAdvance(head) + sfm.horizontalAdvance(expo);
        qreal x = r.right() - total;
        const qreal baseline = r.bottom() - fm.descent();
        p.drawText(QPointF(x, baseline), head);
        x += fm.horizontalAdvance(head);
        p.setFont(sf);
        p.drawText(QPointF(x, baseline - fm.ascent() * 0.45), expo);
        return;
    }

    p.drawText(QPointF(r.right() - fm.horizontalAdvance(text), r.bottom() - fm.descent()), text);
}

void DisplayWidget::paintEvent(QPaintEvent *)
{
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing, true);
    p.setRenderHint(QPainter::TextAntialiasing, true);

    const QRectF full = rect().adjusted(1, 1, -1, -1);
    p.setPen(QPen(kPanelEdge, 2));
    p.setBrush(kPanel);
    p.drawRoundedRect(full, 4, 4);

    const QRectF inner = full.adjusted(kMargin, 6, -kMargin, -6);
    const QRectF status(inner.left(), inner.top(), inner.width(), kStatusHeight);
    drawStatusBar(p, status);

    const qreal resultH = 42.0;
    const QRectF entry(inner.left() + 8, status.bottom() + 6, inner.width() - 16,
                       inner.height() - kStatusHeight - resultH - 10);
    drawEntry(p, entry);

    const QRectF result(inner.left(), inner.bottom() - resultH, inner.width(), resultH);
    drawResult(p, result);
}

} // namespace fx
