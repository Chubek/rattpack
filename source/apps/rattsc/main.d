module apps.rattsc.main;

import rattpack.cli.rattsc : run;

int main(string[] args)
{
    return run(args[1 .. $]);
}
