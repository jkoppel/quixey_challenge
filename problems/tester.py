# make classes for extra classes and then just parse them in
# make version for proper programs

import sys
import subprocess

# let's do just filename, first line is name of program
# other lines will be input args?
name = sys.argv[1]
str_args = sys.argv[2:]
argt = []
for arg in str_args:
    argt.append(eval(arg))



def py_try(name,*args):
    # import from within a folder?
    module = __import__(name)
    fx = getattr(module, name)
    try:
        return fx(*args)
    except:
        return sys.exc_info()



def check(*args):
    py_out = py_try(name,*args)
    p1 = subprocess.Popen(["/usr/bin/java", "Main", name]+str_args, stdout=subprocess.PIPE)
    java_out = p1.stdout.read()


    print "Python: " + str(py_out)
    print "Java: " + str(java_out)


for line in lines:
    check(*argt)