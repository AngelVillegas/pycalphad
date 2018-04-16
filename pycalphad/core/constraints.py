from sympy import ImmutableMatrix, MatrixSymbol, Symbol
from pycalphad.core.sympydiff_utils import AutowrapFunction, CompileLock
from collections import namedtuple


def _build_constraint_functions(variables, constraints, parameters=None):
    if parameters is None:
        parameters = []
    new_parameters = []
    for param in parameters:
        if isinstance(param, Symbol):
            new_parameters.append(param)
        else:
            new_parameters.append(Symbol(param))
    parameters = tuple(new_parameters)
    variables = tuple(variables)
    wrt = variables
    params = MatrixSymbol('params', 1, len(parameters))
    inp_nobroadcast = MatrixSymbol('inp', 1, len(variables))
    args_nobroadcast = []
    for indx in range(len(variables)):
        args_nobroadcast.append(inp_nobroadcast[0, indx])
    for indx in range(len(parameters)):
        args_nobroadcast.append(params[0, indx])

    args = (inp_nobroadcast, params)
    nobroadcast = dict(zip(variables + parameters, args_nobroadcast))
    constraint_func = AutowrapFunction(args, ImmutableMatrix([c.xreplace(nobroadcast) for c in constraints]))

    jacobian = []
    for constraint in constraints:
        sympy_graph_nobroadcast = constraint.xreplace(nobroadcast)
        with CompileLock:
            row = list(sympy_graph_nobroadcast.diff(nobroadcast[i]) for i in wrt)
        jacobian.append(row)
    jacobian_func = AutowrapFunction(args, ImmutableMatrix(jacobian))
    return constraint_func, jacobian_func


ConstraintTuple = namedtuple('ConstraintTuple', ['internal_cons', 'internal_jac', 'multiphase_cons', 'multiphase_jac'])


def build_constraints(mod, conds, parameters=None):
    internal_constraints = mod.get_internal_constraints()
    multiphase_constraints = [Symbol('NP') * mod.get_multiphase_constraint_contribution(cond) for cond in conds.keys()]
    internal_cons, internal_jac = _build_constraint_functions(mod.variables, internal_constraints,
                                                              parameters=parameters)
    multiphase_cons, multiphase_jac = _build_constraint_functions(mod.variables + [Symbol('NP')],
                                                                  multiphase_constraints, parameters=parameters)
    return ConstraintTuple(internal_cons, internal_jac, multiphase_cons, multiphase_jac)