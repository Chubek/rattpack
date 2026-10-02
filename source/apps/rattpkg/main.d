module apps.rattpkg.main;
import rattpack.cli.rattpkg : run;

int main(string[] args)
{
    return run(args[1 .. $]);
}
