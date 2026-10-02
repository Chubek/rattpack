module apps.rattbuild.main;
import rattpack.cli.rattbuild : run;

int main(string[] args)
{
    return run(args[1 .. $]);
}
