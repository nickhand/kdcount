import pyximport
import numpy
import cython
import sharedmem

pyximport.install(setup_args={'include_dirs': [numpy.get_include(), './']})
import pykdcount

pos = numpy.fromfile('badpoints.raw', dtype=('f4', 3))
def process(r, i, j, **kwargs):
    print r, i, j

tree = pykdcount.build(pos)

def allnodes(tree):
    queue = []
    queue.append(tree)
    result = []
    while len(queue) > 0:
        head = queue[0]
        result.append(head)
        queue = queue[1:]
        if head.less is not None:
          queue.append(head.less)
        if head.greater is not None:
          queue.append(head.greater)
    return result

        


