#pragma once
#include <QAbstractButton>

namespace fx {

enum class KeyStyle {
    Dark,    // the black function keys
    Light,   // the pale digit keys
    Accent,  // DEL / AC
    Small    // SHIFT / ALPHA / MENU / ON
};

// A calculator key: big primary legend, plus the small yellow SHIFT legend and
// red ALPHA legend printed on the case above it.
class KeyButton : public QAbstractButton {
    Q_OBJECT
public:
    KeyButton(QString id, QString main, KeyStyle style, QWidget *parent = nullptr);

    void setShiftLabel(const QString &s) { m_shift = s; update(); }
    void setAlphaLabel(const QString &s) { m_alpha = s; update(); }
    void setAltLabel(const QString &s) { m_alt = s; update(); }
    void setHighlighted(bool on);

    QString id() const { return m_id; }
    QSize sizeHint() const override;

protected:
    void paintEvent(QPaintEvent *event) override;

private:
    QString m_id;
    QString m_shift;
    QString m_alpha;
    QString m_alt;
    KeyStyle m_style;
    bool m_highlighted = false;
};

} // namespace fx
