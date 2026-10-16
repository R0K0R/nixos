// Headless check of the calculation core.  Expressions are written in a small
// ASCII shorthand that is fed through the same editor tree the keypad builds:
//   ^{...}  power        f{a}{b}  fraction        r{...}  square root
//   R{n}{x} n-th root    L{b}{x}  log with base   A{...}  absolute value
//   S/C/T   sin/cos/tan (each opens a parenthesis)
#include "core/Engine.h"
#include "core/Node.h"

#include <QCoreApplication>
#include <QString>
#include <cmath>
#include <cstdio>
#include <functional>

using namespace fx;

namespace {

int gFailures = 0;
int gChecks = 0;

struct Builder {
    Engine *engine;
    const QString src;
    int i = 0;

    void run()
    {
        while (i < src.size()) {
            if (src.at(i) == QLatin1Char('}')) { // stray closer: ignore
                ++i;
                continue;
            }
            step();
        }
    }

    // Consumes "{ ... }" into whatever argument the cursor currently sits in.
    void group()
    {
        if (i >= src.size() || src.at(i) != QLatin1Char('{'))
            return;
        ++i;
        while (i < src.size() && src.at(i) != QLatin1Char('}'))
            step();
        if (i < src.size())
            ++i; // consume the closing brace
    }

    void step()
    {
        const QChar ch = src.at(i);
        ++i;
        switch (ch.unicode()) {
        case '^': engine->insertStructure(NodeKind::Power); group(); engine->moveRight(); return;
        case 'f': engine->insertStructure(NodeKind::Frac); group(); engine->moveDown(); group();
                  engine->moveRight(); return;
        case 'r': engine->insertStructure(NodeKind::Sqrt); group(); engine->moveRight(); return;
        case 'R': engine->insertStructure(NodeKind::Root); group(); engine->moveDown(); group();
                  engine->moveRight(); return;
        case 'L': engine->insertStructure(NodeKind::LogBase); group(); engine->moveDown(); group();
                  engine->moveRight(); return;
        case 'A': engine->insertStructure(NodeKind::Abs); group(); engine->moveRight(); return;
        case 'S': engine->insertAtom(QStringLiteral("sin(")); return;
        case 'C': engine->insertAtom(QStringLiteral("cos(")); return;
        case 'T': engine->insertAtom(QStringLiteral("tan(")); return;
        case 'N': engine->insertAtom(QStringLiteral("ln(")); return;
        case 'p': engine->insertAtom(QStringLiteral("pi")); return;
        case 'q': engine->insertAtom(QStringLiteral("sqr")); return;
        case 'v': engine->insertAtom(QStringLiteral("inv")); return;
        case '!': engine->insertAtom(QStringLiteral("!")); return;
        case '%': engine->insertAtom(QStringLiteral("pct")); return;
        case '~': engine->insertAtom(QStringLiteral("neg")); return;
        case 'P': engine->insertAtom(QStringLiteral("nPr")); return;
        case 'B': engine->insertAtom(QStringLiteral("nCr")); return;
        default:  engine->insertAtom(QString(ch)); return;
        }
    }
};

// SOLVE: builds the entry, solves for `var`, and compares the root.
void checkSolve(Engine &e, const char *expr, const char *var, double expected)
{
    ++gChecks;
    e.clearAll();
    e.setAngleUnit(AngleUnit::Deg);
    Builder b{ &e, QString::fromUtf8(expr) };
    b.run();
    const Engine::SolveResult r = e.solveForVariable(QString::fromUtf8(var));
    const bool ok = r.ok && std::fabs(r.value - expected) < 1e-6;
    if (!ok) {
        ++gFailures;
        std::printf("  FAIL  solve %-22s expected %s=%.6f got %s\n", expr, var, expected,
                    r.ok ? QString::number(r.value).toUtf8().constData()
                         : r.error.toUtf8().constData());
    } else {
        std::printf("  ok    solve %-22s -> %s=%.6f (L-R %.1e)\n", expr, var, r.value,
                    r.residual);
    }
}

void check(Engine &e, const char *expr, const char *expected, AngleUnit angle = AngleUnit::Deg)
{
    ++gChecks;
    e.clearAll();
    e.setAngleUnit(angle);
    Builder b{ &e, QString::fromUtf8(expr) };
    b.run();
    const bool ok = e.execute();
    const QString got = ok ? e.resultText() : e.errorText();
    if (got != QString::fromUtf8(expected)) {
        ++gFailures;
        std::printf("  FAIL  %-28s expected %-18s got %s\n", expr, expected,
                    got.toUtf8().constData());
    } else {
        std::printf("  ok    %-28s -> %s\n", expr, got.toUtf8().constData());
    }
}

} // namespace

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    Engine e;

    std::printf("arithmetic and precedence\n");
    check(e, "1+2*3", "7");
    check(e, "6/2(1+2)", "9");            // ClassWiz treats 2( as ordinary x
    check(e, "1/2p", "0.1591549431");     // but 2pi binds tighter than /
    check(e, "2+3*4-6/3", "12");
    check(e, "~5+3", "-2");
    check(e, "2^{10}", "1024");
    check(e, "2^{3^{2}}", "512");      // stacked exponent
    check(e, "2^{3}^{2}", "64");       // exponent closed, then squared
    check(e, "(1+2)^{2}", "9");

    std::printf("\nexact forms (S<=>D standard output)\n");
    check(e, "f{1}{2}+f{1}{3}", "5/6");
    check(e, "f{2}{4}", "1/2");
    check(e, "r{8}", "2√2");
    check(e, "r{2}*r{3}", "√6");
    check(e, "f{1}{r{2}}", "√2/2");
    check(e, "3p", "3π");
    check(e, "f{p}{6}", "π/6");
    check(e, "0.25", "1/4");

    std::printf("\ntrigonometry\n");
    check(e, "S30)", "1/2");
    check(e, "C30)", "√3/2");
    check(e, "T45)", "1");
    check(e, "S180)", "0");
    check(e, "T90)", "Math ERROR");
    check(e, "S0.5)", "0.4794255386", AngleUnit::Rad);
    check(e, "Cp)", "-1", AngleUnit::Rad);

    std::printf("\nfunctions\n");
    check(e, "N1)", "0");
    check(e, "L{2}{8}", "3");
    check(e, "R{3}{27}", "3");
    check(e, "5!", "120");
    check(e, "5P2", "20");
    check(e, "5B2", "10");
    check(e, "A{~7}", "7");
    check(e, "3q", "9");
    check(e, "4v", "1/4");

    std::printf("\nmixed and chained\n");
    check(e, "2+3=", "Syntax ERROR");
    check(e, "1f{1}{2}", "1/2");        // implicit multiply by a fraction
    check(e, "p^{2}", "9.869604401");
    check(e, "100*5%", "5");
    check(e, "r{2}^{2}", "2");

    std::printf("\nSOLVE\n");
    checkSolve(e, "2x+6", "x", -3.0);            // no '=' means "= 0"
    checkSolve(e, "3x-9=0", "x", 3.0);
    checkSolve(e, "x^{2}-4=0", "x", 2.0);
    checkSolve(e, "Sx)=0.5", "x", 30.0);         // degrees
    checkSolve(e, "2D=10", "D", 5.0);   // 'A' is the Abs template in this shorthand

    std::printf("\nerrors\n");
    check(e, "1/0", "Math ERROR");
    check(e, "r{~4}", "Math ERROR");
    check(e, "1+", "Syntax ERROR");

    std::printf("\n%d checks, %d failures\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
