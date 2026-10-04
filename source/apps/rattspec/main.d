module apps.rattspec.main;

import rattpack.cli.rattspec : run;

int main(string[] args)
{
    return run(args[1 .. $]);
}
