#include "ui/CalculatorWindow.h"

#include <QApplication>
#include <QKeyEvent>
#include <QTimer>

namespace {

// --screenshot <file> [keys] renders the window offscreen and exits.  Handy for
// eyeballing the layout without a display server; `keys` is typed first.
void sendKeys(QWidget *w, const QString &keys)
{
    for (const QChar &ch : keys) {
        // '\n' stands in for the Enter key, which has no text of its own.
        const int key = (ch == QLatin1Char('\n')) ? Qt::Key_Return : 0;
        QKeyEvent press(QEvent::KeyPress, key, Qt::NoModifier,
                        key ? QString() : QString(ch));
        QApplication::sendEvent(w, &press);
    }
}

} // namespace

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("fx-570EX"));
    app.setOrganizationName(QStringLiteral("scientific_calculator_qt"));

    const QStringList args = app.arguments();
    const int shotIndex = args.indexOf(QStringLiteral("--screenshot"));

    fx::CalculatorWindow window;
    window.show();

    if (shotIndex > 0 && shotIndex + 1 < args.size()) {
        const QString path = args.at(shotIndex + 1);
        const QString keys = (shotIndex + 2 < args.size()) ? args.at(shotIndex + 2) : QString();
        QTimer::singleShot(300, &window, [&window, path, keys] {
            if (!keys.isEmpty())
                sendKeys(&window, keys);
            QTimer::singleShot(200, &window, [&window, path] {
                window.grab().save(path);
                QApplication::quit();
            });
        });
    }

    return app.exec();
}
