module tests.main;
import unit_threaded;
import tests.core;
import tests.stdlib;

int main(string[] args)
{
    return args.runTests!(tests.core, tests.stdlib);
}
