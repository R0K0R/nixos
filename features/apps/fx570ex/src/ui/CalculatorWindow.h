#pragma once
#include "core/Engine.h"
#include "KeyButton.h"

#include <QHash>
#include <QWidget>

class QGridLayout;

namespace fx {

class DisplayWidget;
class KeyButton;

class CalculatorWindow : public QWidget {
    Q_OBJECT
public:
    explicit CalculatorWindow(QWidget *parent = nullptr);

protected:
    void keyPressEvent(QKeyEvent *event) override;

private:
    void buildKeypad(QGridLayout *grid);
    KeyButton *addKey(QGridLayout *grid, int row, int col, int colSpan, const QString &id,
                      const QString &main, KeyStyle style, const QString &shift = QString(),
                      const QString &alpha = QString(), const QString &alt = QString());
    QWidget *buildDirectionPad();

    void press(const QString &id);
    void handlePlain(const QString &id);
    void handleShifted(const QString &id);
    void handleAlpha(const QString &id);

    void setShift(bool on);
    void setAlpha(bool on);
    void clearModifiers();

    void showSettings();
    void showVariables();
    void showFunctionMenu();
    void runSolve();
    void primeFactorise();

    Engine *m_engine;
    DisplayWidget *m_display;
    QHash<QString, KeyButton *> m_keys;

    bool m_shift = false;
    bool m_alpha = false;
    bool m_storePending = false;
    bool m_recallPending = false;
    bool m_insert = false;
};

} // namespace fx
