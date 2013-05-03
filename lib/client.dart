// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library route.client;

import 'dart:async';
import 'dart:html';

import 'package:logging/logging.dart';

import 'url_matcher.dart';
export 'url_matcher.dart';
import 'url_template.dart';


final _logger = new Logger('route');

typedef RouteEventHandler(RouteEvent path);

/**
 * Route is a node in the tree of routes. The edge leading to the route is
 * defined by path.
 */
class Route {
  final String name;
  final Map<String, Route> _routes = new Map<String, Route>();
  final UrlMatcher path;
  final StreamController<RouteEvent> _onRouteController;
  final StreamController<RouteEvent> _onLeaveController;
  final Route parent;
  Route _defaultRoute;
  Route _currentRoute;
  RouteEvent _lastEvent;

  Stream<RouteEvent> _onRoute;
  Stream<RouteEvent> _onLeave;
  Stream<RouteEvent> get onRoute => _onRoute;
  Stream<RouteEvent> get onLeave => _onLeave;

  Route._new({this.name, this.path, this.parent})
      : _onRouteController = new StreamController<RouteEvent>(),
        _onLeaveController = new StreamController<RouteEvent>() {
    _onRoute = _onRouteController.stream.asBroadcastStream();
    _onLeave = _onLeaveController.stream.asBroadcastStream();
  }

  void addRoute({String name, Pattern path, bool defaultRoute: false,
      RouteEventHandler enter, RouteEventHandler leave, mount}) {
    if (name == null) {
      throw new ArgumentError('name is required for all routes');
    }
    if (_routes.containsKey(name)) {
      throw new ArgumentError('Route $name already exists');
    }

    var matcher;
    if (!(path is UrlMatcher)) {
      matcher = new UrlTemplate(path.toString());
    } else {
      matcher = path;
    }
    var route = new Route._new(name: name, path: matcher, parent: this);

    if (enter != null) {
      route.onRoute.listen(enter);
    }
    if (leave != null) {
      route.onLeave.listen(leave);
    }

    if (mount != null) {
      if (mount is Function) {
        mount(route);
      } else if (mount is Routable) {
        mount.configureRoute(route);
      }
    }

    if (defaultRoute) {
      if (_defaultRoute != null) {
        throw new StateError('Only one default route can be added.');
      }
      _defaultRoute = route;
    }
    _routes[name] = route;
  }

  Route getRoute(String routePath) {
    var routeName = routePath.split('.').first;
    if (!_routes.containsKey(routeName)) {
      _logger.warning('Invalid route name: $routeName $_routes');
      return null;
    }
    var routeToGo = _routes[routeName];
    var childPath = routePath.substring(routeName.length);
    if (!childPath.isEmpty) {
      return routeToGo.getRoute(childPath.substring(1));
    }
    return routeToGo;
  }

  String _getHead(String tail) {
    if (parent == null) {
      return tail;
    }
    if (parent._currentRoute == null) {
      throw new StateError('Router $_parent has no current router.');
    }
    return parent._getHead(parent._currentRoute.reverse(tail));
  }

  String _getTailUrl(String routePath, Map parameters) {
    var routeName = routePath.split('.').first;
    if (!_routes.containsKey(routeName)) {
      throw new StateError('Invalid route name: $routeName');
    }
    var routeToGo = _routes[routeName];
    var tail = '';
    var childPath = routePath.substring(routeName.length);
    if (childPath.length > 0) {
      tail = routeToGo._getTailUrl(childPath.substring(1), parameters);
    }
    return routeToGo.path.reverse(
        parameters: _joinParams(parameters, routeToGo._lastEvent), tail: tail);
  }

  Map _joinParams(Map parameters, RouteEvent lastEvent) {
    if (lastEvent == null) {
      return parameters;
    }
    var joined = new Map.from(lastEvent.parameters);
    joined.addAll(parameters);
    return joined;
  }

  String toString() {
    return '[Route: $name]';
  }

  String reverse(String tail) {
    return path.reverse(parameters: _lastEvent.parameters, tail: tail);
  }

  void renotify() {
    print('$parent ${parent._currentRoute} $this');
    if (parent != null && identical(parent._currentRoute, this)) {
      print('renotify..... YES');
      _onRouteController.add(_lastEvent);
    } else {
      print('renotify..... NO');
    }
  }
}

class RouteEvent {
  final String path;
  final Map parameters;
  var _allowLeaveFutures = <Future<bool>>[];

  RouteEvent(this.path, this.parameters);

  void allowLeave(Future<bool> allow) {
    _allowLeaveFutures.add(allow);
  }

  RouteEvent _clone() => new RouteEvent(path, parameters);
}

abstract class Routable {
  void configureRoute(Route router);
}

/**
 * Stores a set of [UrlPattern] to [Handler] associations and provides methods
 * for calling a handler for a URL path, listening to [Window] history events,
 * and creating HTML event handlers that navigate to a URL.
 */
class Router {
  final bool _useFragment;
  final Window _window;
  final Route root;

  /**
   * [useFragment] determines whether this Router uses pure paths with
   * [History.pushState] or paths + fragments and [Location.assign]. The default
   * value is null which then determines the behavior based on
   * [History.supportsState].
   */
  Router({bool useFragment, Window windowImpl})
      : this._init(null, useFragment: useFragment, windowImpl: windowImpl);

  Router._init(Router parent, {bool useFragment, Window windowImpl})
      : _useFragment = (useFragment == null)
            ? !History.supportsState
            : useFragment,
        _window = (windowImpl == null) ? window : windowImpl,
        root = new Route._new();

  /**
   * Finds a matching [Route] added with [addRoute], parses the path
   * and invokes the associated callback.
   *
   * This method does not perform any navigation, [go] should be used for that.
   * This method is used to invoke a handler after some other code navigates the
   * window, such as [listen].
   *
   * If the UrlPattern contains a fragment (#), the handler is always called
   * with the path version of the URL by converting the # to a /.
   */
  Future<bool> route(String path, {Route startingFrom}) {
    var baseRoute = startingFrom == null ? this.root : startingFrom;
    _logger.finest('route $path $baseRoute');
    Route matchedRoute;
    List matchingRoutes = baseRoute._routes.values.where(
        (r) => r.path.match(path) != null).toList();
    if (!matchingRoutes.isEmpty) {
      if (matchingRoutes.length > 1) {
        _logger.warning("More than one route matches $path $matchingRoutes");
      }
      matchedRoute = matchingRoutes.first;
    } else {
      if (baseRoute._defaultRoute != null) {
        matchedRoute = baseRoute._defaultRoute;
      }
    }
    if (matchedRoute != null) {
      var match = _getMatch(matchedRoute, path);
      if (matchedRoute != baseRoute._currentRoute ||
          baseRoute._currentRoute._lastEvent.path != match.match) {
        return _processNewRoute(baseRoute, path, match, matchedRoute);
      } else {
        baseRoute._currentRoute._lastEvent =
            new RouteEvent(match.match, match.parameters);
        return route(match.tail, startingFrom: matchedRoute);
      }
      return new Future.value(true);
    }
    return new Future.value(true);
  }

  /// Navigates to a given relative route path, and parameters.
  Future go(String routePath, Map parameters,
            {Route startingFrom, bool replace: false}) {
    var baseRoute = startingFrom == null ? this.root : startingFrom;
    var newTail = baseRoute._getTailUrl(routePath, parameters);
    String newUrl = baseRoute._getHead(newTail);
    _logger.finest('go $newUrl');
    return route(newTail, startingFrom: baseRoute).then((success) {
      if (success) {
        _go(newUrl, null, replace);
      }
      return success;
    });
  }

  /// Returns an absolute URL for a given relative route path and parameters.
  String url(String routePath, {Route startingFrom, Map parameters}) {
    var baseRoute = startingFrom == null ? this.root : startingFrom;
    parameters = parameters == null ? {} : parameters;
    return (_useFragment ? '#' : '') +
        baseRoute._getHead(baseRoute._getTailUrl(routePath, parameters));
  }

  Router getRouter(String routePath) {
    var routeName = routePath.split('.').first;
    if (!_routes.containsKey(routeName)) {
      throw new StateError('Invalid route name: $routeName');
    }
    var routeToGo = _routes[routeName];
    var childPath = routePath.substring(routeName.length);
    if (routeToGo.child != null && childPath.length > 0) {
      return routeToGo.getRouter(childPath.substring(1));
    }
    return routeToGo.router;
  }

  UrlMatch _getMatch(Route route, String path) {
    var match = route.path.match(path);
    if (match == null) { // default route
      return new UrlMatch('', '', {});
    }
    return match;
  }

  Future<bool> _processNewRoute(Route base, String path, UrlMatch match,
      Route newRoute) {
    var event = new RouteEvent(match.match, match.parameters);
    // before we make this a new current route, leave the old
    return _leaveCurrentRoute(base, event).then((bool allowNavigation) {
      if (allowNavigation) {
        _unsetAllCurrentRoutes(base);
        base._currentRoute = newRoute;
        base._currentRoute._lastEvent =
            new RouteEvent(match.match, match.parameters);
        newRoute._onRouteController.add(event);
        return route(match.tail, startingFrom: newRoute);
      }
      return true;
    });
  }

  void _unsetAllCurrentRoutes(Route r) {
    if (r._currentRoute != null) {
      _unsetAllCurrentRoutes(r._currentRoute);
      r._currentRoute = null;
    }
  }

  Future<bool> _leaveCurrentRoute(Route base, RouteEvent e) =>
      Future.wait(_leaveCurrentRouteHelper(base, e))
          .then((values) => values.fold(true, (c, v) => c && v));

  List<Future<bool>> _leaveCurrentRouteHelper(Route base, RouteEvent e) {
    var futures = [];
    if (base._currentRoute != null) {
      List<Future<bool>> pendingResponses = <Future<bool>>[];
      // We create a copy of the route event
      var event = e._clone();
      base._currentRoute._onLeaveController.add(event);
      futures.addAll(event._allowLeaveFutures);
      futures.addAll(_leaveCurrentRouteHelper(base._currentRoute, event));
    }
    return futures;
  }

  /**
   * Listens for window history events and invokes the router. On older
   * browsers the hashChange event is used instead.
   */
  void listen({bool ignoreClick: false}) {
    if (_useFragment) {
      _window.onHashChange.listen((_) {
        return route(_normalizeHash(_window.location.hash));
      });
      route(_normalizeHash(_window.location.hash));
    } else {
      _window.onPopState.listen((_) => route(_window.location.pathname));
    }
    if (!ignoreClick) {
      _window.onClick.listen((e) {
        if (e.target is AnchorElement) {
          AnchorElement anchor = e.target;
          if (anchor.host == _window.location.host) {
            e.preventDefault();
            var fragment = (anchor.hash == '') ? '' : '${anchor.hash}';
            route('${anchor.pathname}$fragment').then((allowed) {
              if (allowed) {
                _go("${anchor.pathname}$fragment", null, false);
              }
            });
          }
        }
      });
    }
  }

  String _normalizeHash(String hash) {
    if (hash.isEmpty) {
      return '';
    }
    return hash.substring(1);
  }

  /**
   * Navigates the browser to the path produced by [url] with [args] by calling
   * [History.pushState], then invokes the handler associated with [url].
   *
   * On older browsers [Location.assign] is used instead with the fragment
   * version of the UrlPattern.
   */
  Future<bool> gotoUrl(String url) {
    return route(url).then((success) {
      if (success) {
        _go(url, null);
      }
    });
  }

  void _go(String path, String title, bool replace) {
    title = (title == null) ? '' : title;
    if (_useFragment) {
      if (replace) {
        _window.location.replace('#$path');
      } else {
        _window.location.assign('#$path');
      }
      (_window.document as HtmlDocument).title = title;
    } else {
      if (replace) {
        _window.history.replaceState(null, title, path);
      } else {
        _window.history.pushState(null, title, path);
      }
    }
  }
}
