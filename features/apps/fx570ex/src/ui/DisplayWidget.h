#pragma once
#include "core/Engine.h"

#include <QTimer>
#include <QWidget>

namespace fx {

// The LCD panel: a status strip, the natural-display entry line, and the
// right-aligned result.  Colours follow the physical unit (ink 30,52,90 on a
// pale green-grey panel).
class DisplayWidget : public QWidget {
    Q_OBJECT
public:
    explicit DisplayWidget(Engine *engine, QWidget *parent = nullptr);

    void setShiftActive(bool on);
    void setAlphaActive(bool on);
    void setInsertMode(bool on);

    QSize sizeHint() const override { return QSize(520, 190); }

protected:
    void paintEvent(QPaintEvent *event) override;
    void resizeEvent(QResizeEvent *event) override;

private:
    void drawStatusBar(QPainter &p, const QRectF &r);
    void drawEntry(QPainter &p, const QRectF &r);
    void drawResult(QPainter &p, const QRectF &r);

    Engine *m_engine;
    QTimer m_blink;
    bool m_cursorOn = true;
    bool m_shift = false;
    bool m_alpha = false;
    bool m_insert = false;
    qreal m_scrollX = 0.0;
};

} // namespace fx
