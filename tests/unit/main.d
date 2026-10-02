module tests.main;
import unit_threaded;
import tests.core;

int main(string[] args)
{
    return args.runTests!(tests.core);
}
